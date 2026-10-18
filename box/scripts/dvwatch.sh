#!/system/bin/sh
# Ловит смену формата видео на выходе (Dolby Vision <-> HDR10) и пишет,
# на какой минуте какого фильма это было. Только читает журнал, ничего не меняет.
# Формат по драйверу Amlogic: -1 нет кадра, 0 SDR, 1 HDR10, 4 HLG, 5 Dolby Vision.

LOG=/data/local/tmp/aria2/dvwatch.log

kodi() {
  body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
  printf 'POST /jsonrpc HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' \
    ${#body} "$body" | nc -w 2 127.0.0.1 8090 2>/dev/null | tail -n 1
}

pos() {
  kodi Player.GetProperties '{"playerid":1,"properties":["time","speed"]}' \
    | sed -E 's/.*"speed":(-?[0-9]+).*"hours":([0-9]+).*"minutes":([0-9]+),"seconds":([0-9]+).*/\2:\3:\4 скорость=\1/'
}

what() {
  kodi Player.GetItem '{"playerid":1,"properties":["file"]}' | sed -E 's/.*"label":"([^"]*)".*/\1/'
}

echo "$(date '+%F %T') старт" >> "$LOG"
logcat -T 1 -v time 'MesonHwc:D' '*:S' | while read -r line; do
  case "$line" in
    *VIDEO_FORMAT=*)
      echo "$(date '+%F %T') формат=${line##*VIDEO_FORMAT=} | $(what) | $(pos)" >> "$LOG" ;;
    *"set color space from"*)
      echo "$(date '+%F %T') HDMI ${line##*set color space }" >> "$LOG" ;;
  esac
done
