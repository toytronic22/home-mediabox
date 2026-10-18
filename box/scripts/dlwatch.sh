#!/system/bin/sh
# Сторож закачек: следит за окончанием загрузок и при желании выключает приставку.
# Держать приставку бодрой не требуется — она и так не засыпает по-настоящему
# (проверено: без блокировки во сне закачка продолжается, suspend_stats = 0).
#
# Выключение по умолчанию ВЫКЛЮЧЕНО. Включается наличием файла autopoweroff
# (команда с мака: ugoos poweroff on).
# Выключит только если одновременно: было что качать и всё докачалось; экран погашен
# (значит никто не смотрит); ничего не играет; и прошла отсрочка GRACE.
BIN=/data/local/tmp/aria2
FLAG=$BIN/autopoweroff
LOG=$BIN/dlwatch.log
PERIOD=30          # как часто проверять, секунд
GRACE=180          # сколько ждать после окончания загрузок перед выключением

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Только один экземпляр: иначе два сторожа дерутся за блокировку и могут дважды
# решить выключить приставку.
PIDFILE=$BIN/dlwatch.pid
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -q dlwatch "/proc/$old/cmdline" 2>/dev/null; then
        log "уже запущен (pid $old) — выхожу"
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' TERM INT

# Сколько задач в работе (качаются или ждут очереди). Печатает число, при
# недоступности качалки — "?", и тогда выключение откладывается: пропавшая связь
# не повод гасить приставку посреди закачки.
# Раньше здесь aria2c ходил в RPC арии; qBittorrent отвечает обычным JSON по nc.
active_count() {
  out=$({ printf 'GET /api/v2/torrents/info HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n'; sleep 2; } \
        | timeout 12 nc 127.0.0.1 8080 2>/dev/null)
  case "$out" in
    *'"hash"'*) ;;
    *'[]'*)     printf '0'; return ;;
    *)          printf '?'; return ;;
  esac
  # считаем всё, что ещё не докачано: качается, стоит в очереди, тормозит без пиров
  n=$(printf '%s' "$out" | sed 's/},{/}\n{/g' \
      | grep -cE '"state":"(downloading|stalledDL|queuedDL|metaDL|checkingDL|forcedDL|allocating)"')
  printf '%s' "${n:-0}"
}

screen_off() { dumpsys power 2>/dev/null | grep -q 'mWakefulness=Asleep'; }
media_playing() {
  dumpsys audio 2>/dev/null | grep 'AudioPlaybackConfiguration' \
    | grep 'state:started' | grep -q 'usage=USAGE_\(MEDIA\|GAME\)'
}
# Блокировка сна НЕ используется намеренно. Замерено: приставка никогда не уходит
# в глубокий сон (suspend_stats/success = 0 даже без блокировки), закачка во сне идёт.
# А трогать управление питанием на этой прошивке опасно — ядро и так падает в панику.

ARMED=0        # было ли что качать с момента запуска
IDLE_SINCE=0

log "сторож запущен (проверка раз в ${PERIOD}с, отсрочка выключения ${GRACE}с)"
while :; do
    n=$(active_count)
    if [ "$n" = "?" ]; then
        sleep "$PERIOD"; continue                  # качалка молчит — ничего не решаем
    fi
    if [ "$n" -gt 0 ]; then
        if [ "$ARMED" -eq 0 ]; then log "качается задач: $n"; fi
        ARMED=1; IDLE_SINCE=0
    else
        if [ "$ARMED" -eq 1 ]; then
            now=$(cat /proc/uptime | cut -d. -f1)
            if [ "$IDLE_SINCE" -eq 0 ]; then
                IDLE_SINCE=$now
                log "все загрузки завершены"
                [ -e "$FLAG" ] && log "выключение включено — жду ${GRACE}с и проверю, свободна ли приставка"
            fi
            if [ -e "$FLAG" ] && [ $((now - IDLE_SINCE)) -ge "$GRACE" ]; then
                if media_playing; then
                    log "идёт воспроизведение — выключение отложено"
                    IDLE_SINCE=$now
                elif ! screen_off; then
                    log "экран включён, кто-то пользуется — выключение отложено"
                    IDLE_SINCE=$now
                else
                    log "загрузок нет, экран погашен, ничего не играет — ВЫКЛЮЧАЮ"
                    sync
                    reboot -p
                    sleep 30
                fi
            fi
        fi
    fi
    sleep "$PERIOD"
done
