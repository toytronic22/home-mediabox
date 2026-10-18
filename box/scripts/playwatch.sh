#!/system/bin/sh
# Прибор для разбора заминок при просмотре. Пишет строку раз в 5 секунд, но ТОЛЬКО пока
# Kodi что-то играет — в покое молчит и почти ничего не стоит (два чтения из /proc).
#
# Зачем. 13.09.2026 фильм спотыкался, а доказать причину было нечем: health.sh пишет
# температуру, память и напряжение — и ни одной дисковой метрики. Из-за этого «виноват диск»
# и «виноват процессор» были неразличимы. Теперь пишем три вещи, которые их разделяют:
#   * дельта /sys/block/sda/stat — сколько диск реально отдал, за сколько запросов и с какой
#     задержкой на запрос (поля 1,3,4,10: запросы, секторы, суммарные мс, занятость);
#   * /proc/pressure/io — доля времени, когда задачи стояли на вводе-выводе (full = все);
#   * запас Kodi: cachepercentage минус позиция = сколько прочитано вперёд.
# Если в момент рывка io full подскакивает, задержка растёт, а запас падает — это диск.
# Если PSI ровное и запас полон — это не подача данных, и копать надо в плеере.
BIN=/data/local/tmp/aria2
# Общие функции — журнал, обращение к качалке и к Kodi, ротация, проверка диска.
# Вынесены в один файл 14.09.2026: до этого копии жили в девяти скриптах и расходились
# в мелочах (обрезка заголовков HTTP, таймауты), из-за чего работали по случайности.
. /data/local/tmp/aria2/lib.sh
api() { kodi_rpc "$1"; }

LOG=$BIN/play.log
S=/sys/block/sda/stat

num() { printf '%s' "$1" | grep -o "\"$2\":[0-9.eE+-]*" | head -1 | cut -d: -f2; }

prev=""; pt=0; was=0
while :; do
    # Сперва спрашиваем, играет ли вообще что-нибудь: Player.GetProperties отвечает
    # осмысленно и при отсутствии плеера (нули), и по нему просмотр не определить.
    act=$(api '{"jsonrpc":"2.0","id":1,"method":"Player.GetActivePlayers"}')
    case "$act" in
        *'"playerid"'*) r=$(api '{"jsonrpc":"2.0","id":1,"method":"Player.GetProperties","params":{"playerid":1,"properties":["percentage","cachepercentage","speed"]}}') ;;
        *) r="" ;;
    esac
    case "$r" in
        *percentage*)
            [ "$was" = 0 ] && {
                echo "# $(date '+%F %T') начало просмотра | время | поз% | вперёд% | чтение МБ/с | запрос КБ | задержка мс | занят% | запись МБ/с | io some/full | cpu some | своб МБ | загрузка" >> "$LOG"
                prev=$(cat $S); pt=$(date +%s); was=1; sleep 5; continue
            }
            now=$(date +%s); dt=$((now - pt)); [ "$dt" -lt 1 ] && dt=1
            cur=$(cat $S)
            d=$(echo "$prev $cur" | awk -v dt=$dt '{n=NF/2; for(i=1;i<=n;i++) x[i]=$(i+n)-$i;
                printf "%.1f %.0f %.0f %.0f %.1f", x[3]*512/dt/1048576, (x[1]?x[3]*512/x[1]/1024:0), (x[1]?x[4]/x[1]:0), x[10]/dt/10, x[7]*512/dt/1048576}')
            prev=$cur; pt=$now
            io=$(awk '/^full/{print $2}' /proc/pressure/io 2>/dev/null | cut -d= -f2)
            ios=$(awk '/^some/{print $2}' /proc/pressure/io 2>/dev/null | cut -d= -f2)
            cpu=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | cut -d= -f2)
            p=$(num "$r" percentage); c=$(num "$r" cachepercentage)
            ahead=$(awk -v a="${c:-0}" -v b="${p:-0}" 'BEGIN{printf "%.2f", a-b}')
            printf '%s | %s | %s | %s | %s/%s | %s | %d | %s\n' \
                "$(date '+%T')" "${p:-?}" "$ahead" "$d" "${ios:-?}" "${io:-?}" "${cpu:-?}" \
                "$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)" "$(cut -d' ' -f1 /proc/loadavg)" >> "$LOG"
            ;;
        *)  [ "$was" = 1 ] && { echo "# $(date '+%F %T') просмотр окончен" >> "$LOG"; was=0; } ;;
    esac
    sleep 5
done
