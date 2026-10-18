#!/system/bin/sh
# Сборщик показаний приставки: раз в минуту пишет строку в health.log.
# Нужен, чтобы после следующей паники ядра увидеть, что менялось перед ней:
# температура, качество Wi-Fi, скорость закачки, число соединений, память.
# Только чтение, ничего не трогает. Лог обрезается до последних 3000 строк.
BIN=/data/local/tmp/aria2
# Общие функции — журнал, обращение к качалке и к Kodi, ротация, проверка диска.
# Вынесены в один файл 14.09.2026: до этого копии жили в девяти скриптах и расходились
# в мелочах (обрезка заголовков HTTP, таймауты), из-за чего работали по случайности.
. /data/local/tmp/aria2/lib.sh
HDD=/mnt/media_rw/FA9E-9466
LOG=$BIN/health.log

temp() { awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null; }
cpufreq() { awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null; }
wifi() {
  # скорость линка и уровень сигнала из штатной утилиты
  l=$(/system/bin/iw dev wlan0 link 2>/dev/null)  # только абсолютный путь: у init-службы PATH пустой
  if [ -n "$l" ]; then
    printf '%s/%s' \
      "$(printf '%s' "$l" | grep -o 'signal: *[-0-9]*' | grep -o '[-0-9]*$' | head -1)" \
      "$(printf '%s' "$l" | sed -n 's/.*tx bitrate: *\([0-9.]*\).*/\1/p' | head -1)"
  else
    printf '%s/%s' "$(dumpsys wifi 2>/dev/null | grep -o 'RSSI: *[-0-9]*' | grep -o '[-0-9]*$' | head -1)" "?"
  fi
}
conns() { ss -tn state established 2>/dev/null | wc -l; }
# Скорость и число активных задач — у качалки одним запросом. Раньше здесь
# работал aria2c в роли HTTP-клиента; qBittorrent отвечает обычным JSON, поэтому
# хватает nc. Пауза перед закрытием обязательна: nc на Android рвёт соединение
# по концу stdin, и собеседник не успевает ответить.
dlspeed() {
  o=$({ printf 'GET /api/v2/transfer/info HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n'; sleep 2; } \
      | timeout 10 nc 127.0.0.1 8080 2>/dev/null)
  case "$o" in
    *dl_info_speed*)
      sp=$(printf '%s' "$o" | sed -n 's/.*"dl_info_speed":\([0-9]*\).*/\1/p')
      n=$({ printf 'GET /api/v2/torrents/info?filter=downloading HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n'; sleep 2; } \
          | timeout 10 nc 127.0.0.1 8080 2>/dev/null | grep -o '"hash"' | wc -l)
      printf '%s/%s' "$(printf '%s' "${sp:-0}" | awk '{printf "%.1f", $1/1048576}')" "$n"
      ;;
    *) printf '?/?' ;;
  esac
}
mem() { awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo; }
# Сколько места на внешнем диске — для веб-интерфейса файлов: он читает этот файл
# и рисует шкалу. Байты считаем в awk: в оболочке приставки арифметика 32-битная
# и на терабайте переполнилась бы. Диск отключён — файл убираем, шкала просто исчезнет.
# Сводка о свободном месте для вебморды. Пишется на медиадиск, поэтому — только когда
# значение реально изменилось. 13.09.2026 этот файл переписывался каждые 5 минут просто так,
# и во время фильма ловился «кружок загрузки» ровно с этим периодом: на SMR-диске даже
# крошечная запись тянет за собой транзакцию журнала, а буфера у плеера тогда не было вовсе.
# Когда закачки стоят, свободное место не меняется — значит за весь фильм ни одной записи.
DISKINFO_STEP=262144     # порог изменения, КБ (256 МБ)
DISKINFO_MAXAGE=21600    # но не реже раза в 6 часов, чтобы метка времени не протухала
DISKINFO_LAST=""
DISKINFO_WHEN=0
diskinfo() {
    out=$HDD/.diskinfo.json
    if [ ! -d "$HDD/Video" ]; then rm -f "$out" 2>/dev/null; DISKINFO_LAST=""; return 0; fi
    set -- $(df -k "$HDD" 2>/dev/null | tail -1)
    total=$2; free=$4
    [ -n "$free" ] || return 0
    now=$(date +%s)
    if [ -n "$DISKINFO_LAST" ] && [ -f "$out" ]; then
        d=$((free - DISKINFO_LAST)); [ "$d" -lt 0 ] && d=$((-d))
        [ "$d" -lt "$DISKINFO_STEP" ] && [ $((now - DISKINFO_WHEN)) -lt "$DISKINFO_MAXAGE" ] && return 0
    fi
    awk -v t="$total" -v f="$free" -v ts="$now" \
      'BEGIN{printf "{\"total\":%.0f,\"free\":%.0f,\"ts\":%d}\n", t*1024, f*1024, ts}' \
      > "$out.new" 2>/dev/null && mv -f "$out.new" "$out" 2>/dev/null && chmod 644 "$out" 2>/dev/null \
      && { DISKINFO_LAST=$free; DISKINFO_WHEN=$now; }
}
# Напряжение блока питания: приставке нужно ровно 12 В. Проседание ниже ~11,5 В
# под нагрузкой = блок не тянет, и это прямая причина зависаний и перезагрузок.
# Что делает диск. 13.09.2026 фильм спотыкался, а доказать причину было нечем: здесь писались
# температура, память и напряжение — и ни одной дисковой метрики, из-за чего «виноват диск» и
# «виноват плеер» оказались неразличимы задним числом. Считаем разницей с прошлого прохода по
# /sys/block/sda/stat: поле 3 — прочитано секторов, 4 — суммарные мс ожидания чтения,
# 7 — записано секторов, 10 — мс, когда устройство было занято.
# Состояние держим в ФАЙЛЕ, а не в переменной: disk_io вызывается через $(...), то есть в
# подоболочке, и присваивание внутри неё до следующего вызова не доживает (поймано 14.09.2026 —
# колонка три часа писала прочерк).
DISK_PREV_F=$BIN/.diskstat.prev
disk_io() {
    [ -r /sys/block/sda/stat ] || { printf '?'; return 0; }
    now=$(date +%s)
    cur="$now $(cat /sys/block/sda/stat)"
    if [ ! -s "$DISK_PREV_F" ]; then printf '%s' "$cur" > "$DISK_PREV_F"; printf -- '-'; return 0; fi
    prev=$(cat "$DISK_PREV_F")
    printf '%s' "$cur" > "$DISK_PREV_F"
    echo "$prev $cur" | awk '{ dt = $(NF/2+1) - $1; if (dt < 1) dt = 1
        n = (NF - 2) / 2
        for (i = 1; i <= n; i++) d[i] = $(i + 1 + n + 1) - $(i + 1)
        printf "%.1f/%.1f/%.0f/%.0f", d[3]*512/dt/1048576, d[7]*512/dt/1048576, (d[1] ? d[4]/d[1] : 0), d[10]/dt/10 }'
}
volts() { awk '{printf "%.2f", $1/1000000}' /sys/class/power_supply/dc_in/voltage_now 2>/dev/null; }

[ -s "$LOG" ] || echo "# время | аптайм_с | темп_C | ЦП_МГц | сигнал_дБм/линк_Мбит | соед | скачка_МБс/задач | своб_память_МБ | загрузка | питание_В | диск_чтение/запись_МБс/задержка_мс/занят_%" > "$LOG"

# Логи пишутся месяцами, а разбираться в них имеет смысл только по свежим следам.
# Поэтому подрезаем: как только файл перевалит порог, оставляем последние строки.
# Заодно присматриваем за журналом качалки — он растёт быстрее нашего.

rotate() {
    rotate_one "$LOG" 204800 500
    rotate_one /data/local/tmp/qbt/logs/qbittorrent.log 524288 300
    rotate_one "$BIN/sort.log" 102400 200
    rotate_one "$BIN/dlwatch.log" 102400 200
    rotate_one "$BIN/videoraw.log" 51200 100
    # play.log пишется раз в 5 с, пока идёт кино (≈720 строк в час) — режем чаще прочих.
    rotate_one "$BIN/play.log" 204800 400
}

while :; do
    rotate
    diskinfo
    printf '%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n' \
      "$(date '+%F %T')" "$(cut -d. -f1 /proc/uptime)" "$(temp)" "$(cpufreq)" \
      "$(wifi)" "$(conns)" "$(dlspeed)" "$(mem)" "$(cut -d' ' -f1 /proc/loadavg)" "$(volts)" "$(disk_io)" >> "$LOG"
    # не даём логу расти бесконечно
    lines=$(wc -l < "$LOG")
    if [ "$lines" -gt 3000 ]; then tail -2000 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; fi
    sleep 300
done
