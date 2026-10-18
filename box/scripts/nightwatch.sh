#!/system/bin/sh
# Ночной наблюдатель: раз в минуту пишет состояние диска и качалки, до 07:00, и при
# каждой просадке скорости ставит диагноз — сеть (сиды) или диск (винт).
#
# Поставлен в ночь на 11.09.2026 после включения TRIM, чтобы утром было видно, что
# происходило под непрерывной закачкой. Дополняет health.log (там раз в 5 минут и без
# дисковой статистики). Только читает, ничего не трогает.
#
# Как ставится диагноз при скорости сети ниже SLOW_MB:
#   винт — качалка сама сообщает о перегрузе дисковой очереди (write_cache_overload — это
#          процент, в 5.x строка вида "68.18"; порог 50),
#          либо в очереди на запись больше 8 МБ или 32 заданий, либо латентность записи ≥300 мс,
#          либо грязных страниц ≥300 МБ, либо диск занят ≥95 %, а пишет меньше 4 МБ/с;
#   сиды — раздача в состоянии stalledDL (пиры не дают данных), либо подключено 0 сидов,
#          либо подключено ≤2 при ≤5 сидах в рое вообще;
#   лимит — скорость упёрлась в потолок сторожа (это не просадка);
#   ?    — ни то, ни другое: смотреть глазами.
BIN=/data/local/tmp/aria2
LOG=$BIN/night.log
S=/sys/block/sda/stat
END_H=7
SLOW_MB=4

api() {
    { printf 'GET /api/v2/%s HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n' "$1"; sleep 2; } \
      | timeout 10 nc 127.0.0.1 8080 2>/dev/null | tail -1
}
# Разбор JSON только через grep -o: sed с жадным .* на 30-килобайтной строке maindata
# у toybox уходит в перебор на минуты (поймано 11.09.2026 — наблюдатель молчал).
num() { printf '%s' "$1" | grep -o "\"$2\":[0-9.eE+-]*" | head -1 | cut -d: -f2; }
str() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

echo "# время | аптайм с | диск: запись МБ/с, латентность мс, чтение МБ/с, занят %, discard | грязных МБ | загрузка | свободно МБ | темп | сеть вниз МБ/с / лимит | очередь диска: заданий, МБ, перегруз | активная: имя, %, сиды подкл/в рое, пиры, состояние | ДИАГНОЗ" >> "$LOG"
echo "$(date '+%F %T') наблюдение начато" >> "$LOG"
prev=$(cat $S 2>/dev/null); pt=$(date +%s); last_diag=норма
while :; do
    sleep 60
    h=$(date +%H); h=${h#0}
    if [ "${h:-0}" -ge $END_H ] && [ "${h:-0}" -lt 12 ]; then echo "$(date '+%F %T') наблюдение окончено (07:00)" >> "$LOG"; exit 0; fi

    # --- диск ---
    now=$(date +%s); dt=$((now - pt)); [ "$dt" -lt 1 ] && dt=1
    w=0; lat=0; busy=0
    if [ -f $S ]; then
        cur=$(cat $S)
        set -- $(echo "$prev $cur" | awk -v dt=$dt '{n=NF/2; for(i=1;i<=n;i++) d[i]=$(i+n)-$i;
            printf "%.1f %.0f %.1f %.0f %d", d[7]*512/dt/1048576, (d[5]?d[8]/d[5]:0), d[3]*512/dt/1048576, d[10]/dt/10, d[12]}')
        w=$1; lat=$2; busy=$4
        disk="$1, $2 мс, $3, $4%, $5"
        prev=$cur
    else
        disk="ДИСК ПРОПАЛ ($(ls /sys/block | grep -E '^sd' | tr '\n' ' '))"
    fi
    [ -d /storage/FA9E-9466/Video ] || disk="$disk, ТОЧКА НЕ СМОНТИРОВАНА"
    pt=$now
    dirty=$(awk '/^Dirty:/{printf "%d", $2/1024}' /proc/meminfo)
    load=$(cut -d' ' -f1 /proc/loadavg)
    mem=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    temp=$(awk '{printf "%.0f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)

    # --- качалка: общее состояние ---
    o=$(api "sync/maindata" | grep -o '"server_state":{[^}]*}')
    case "$o" in
        *dl_info_speed*)
            dl=$(num "$o" dl_info_speed | awk '{printf "%.1f", $1/1048576}')
            lim=$(num "$o" dl_rate_limit | awk '{printf "%.0f", $1/1048576}')
            qjobs=$(num "$o" queued_io_jobs); qmb=$(num "$o" total_queued_size | awk '{printf "%.1f", $1/1048576}')
            over=$(str "$o" write_cache_overload)
            net="$dl / $lim"; queue="$qjobs, $qmb МБ, перегруз=$over" ;;
        *)  dl=""; lim=0; qjobs=0; qmb=0; over=0; net="API НЕ ОТВЕЧАЕТ"; queue="-" ;;
    esac
    # --- активная раздача: сначала та, что качает, иначе та, что стоит без данных ---
    a=$(api "torrents/info?filter=active&limit=1")
    case "$a" in *'"state"'*) ;; *) a=$(api "torrents/info?filter=stalled_downloading&limit=1") ;; esac
    case "$a" in
        *'"state"'*)
            aname=$(str "$a" name | cut -c1-38); ast=$(str "$a" state)
            aprog=$(num "$a" progress | awk '{printf "%.1f%%", $1*100}')
            seeds=$(num "$a" num_seeds); seeds_all=$(num "$a" num_complete); leech=$(num "$a" num_leechs)
            active="$aname, $aprog, сиды $seeds/$seeds_all, пиры $leech, $ast" ;;
        *)  aname=""; ast=none; seeds=0; seeds_all=0; leech=0; active="нет активных" ;;
    esac

    # --- диагноз ---
    diag=$(awk -v dl="${dl:-0}" -v api="${dl:+1}" -v lim="$lim" -v slow=$SLOW_MB -v over="${over:-0}" -v qmb="${qmb:-0}" -v qjobs="${qjobs:-0}" \
               -v lat="$lat" -v dirty="${dirty:-0}" -v busy="$busy" -v w="$w" -v st="$ast" -v seeds="${seeds:-0}" -v sall="${seeds_all:-0}" 'BEGIN{
        if (api != 1)                 { print "API НЕ ОТВЕЧАЕТ"; exit }
        if (st == "none")             { print "стоп (нет активных)"; exit }
        if (dl >= slow)               { print "норма"; exit }
        if (lim > 0 && dl >= lim*0.8) { print "лимит"; exit }
        disk = (over+0 >= 50 || qmb >= 8 || qjobs >= 32 || lat >= 300 || dirty >= 300 || (busy >= 95 && w < 4))
        net  = (st == "stalledDL" || seeds == 0 || (seeds <= 2 && sall <= 5))
        if (disk && !net) print "ПРОСАДКА: винт"
        else if (net && !disk) print "ПРОСАДКА: сиды"
        else if (disk && net) print "ПРОСАДКА: винт+сиды"
        else print "ПРОСАДКА: ?"
    }')

    printf '%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n' \
        "$(date '+%F %T')" "$(cut -d. -f1 /proc/uptime)" "$disk" "$dirty" "$load" "$mem" "$temp" "$net" "$queue" "$active" "$diag" >> "$LOG"
    if [ "$diag" != "$last_diag" ]; then
        case "$diag" in
            ПРОСАДКА*) echo "$(date '+%F %T') !! $diag — сеть $dl МБ/с, диск пишет $w МБ/с с латентностью $lat мс, грязных $dirty МБ, очередь $qmb МБ (перегруз=$over), сиды $seeds/$seeds_all, $ast" >> "$LOG" ;;
            *) case "$last_diag" in ПРОСАДКА*) echo "$(date '+%F %T') !! просадка кончилась → $diag (сеть $dl МБ/с)" >> "$LOG" ;; esac ;;
        esac
        last_diag=$diag
    fi
done
