#!/system/bin/sh
# Кнопки «Перезагрузить» и «Выключить» в файловом менеджере.
#
# Как устроено: вебморда dufs — это файловый сервер, выполнять команды она не умеет. Поэтому
# кнопка просто создаёт файл-команду в скрытой папке .control на диске (PUT через тот же dufs,
# он запущен с --allow-all), а этот сторож раз в две секунды смотрит, не появился ли такой файл.
#
# Почему не гасим приставку в лоб: если оборвать qBittorrent на полуслове, при следующем запуске
# он перепроверит все раздачи — это часы чтения 583 ГБ на нашем черепичном диске. Поэтому сперва
# штатно закрываем качалку и ждём, пока она сохранит состояние, и только потом выключаемся.
BIN=/data/local/tmp/aria2
# Общие функции — журнал, обращение к качалке и к Kodi, ротация, проверка диска.
# Вынесены в один файл 14.09.2026: до этого копии жили в девяти скриптах и расходились
# в мелочах (обрезка заголовков HTTP, таймауты), из-за чего работали по случайности.
. /data/local/tmp/aria2/lib.sh
HDD=/mnt/media_rw/FA9E-9466
CTL=$HDD/.control
LOG=$BIN/power.log
QBT_WAIT=30


# ВАЖНО: при старте стираем всё, что лежало в .control. Иначе файл, оставшийся от команды
# «выключить» (например, приставку обесточили раньше, чем сторож успел его убрать), заставил бы
# её выключаться снова и снова при каждой загрузке.
rm -f "$CTL"/reboot "$CTL"/poweroff "$CTL"/qbt-on "$CTL"/sleep "$CTL"/wake 2>/dev/null
mkdir -p "$CTL" 2>/dev/null
chown 2000:1023 "$CTL" 2>/dev/null; chmod 2775 "$CTL" 2>/dev/null
log "сторож кнопок запущен"

shutdown_gracefully() {
    what=$1
    log "команда «$what» — готовлюсь"
    # сторож закачек сам перезапускает качалку, поэтому сперва останавливаем его
    stop ariaguard 2>/dev/null
    # Раздачи на паузу И ЖДЁМ, пока качалка запишет отметки о прогрессе. Без ожидания она
    # успевает умереть раньше записи — проверено 14.09.2026, потерялось 1,6 ГБ прогресса
    # (данные на диске были целы, но качалка собиралась качать их заново).
    if qbt_alive; then
        qbt_flush_resume && log "отметки о прогрессе записаны" || log "качалка не записала отметки за 20 с — после загрузки возможна перекачка"
    fi
    # штатно закрываем качалку и ждём, пока сохранится
    if pidof qbittorrent-nox >/dev/null 2>&1; then
        stop qbt 2>/dev/null
        i=0
        while pidof qbittorrent-nox >/dev/null 2>&1 && [ "$i" -lt "$QBT_WAIT" ]; do sleep 1; i=$((i + 1)); done
        if pidof qbittorrent-nox >/dev/null 2>&1; then
            log "качалка не закрылась за ${QBT_WAIT} с — иду дальше, добивать не буду"
        else
            log "качалка закрылась за ${i} с"
        fi
    fi
    sync
    log "выполняю: $what"
    sleep 1
    case "$what" in
        poweroff) reboot -p ;;
        *)        reboot ;;
    esac
    # если сюда вернулись, команда не сработала
    sleep 20
    log "команда «$what» не сработала — поднимаю сторож закачек обратно"
    start ariaguard 2>/dev/null
}

# Ручное включение загрузок. После фильма сторож поднимает качалку сам, но только через
# 20 спокойных минут — чтобы она не дёргалась туда-сюда, когда кино ставят на паузу. Эта кнопка
# отменяет ожидание и поднимает её сразу. Отсчёт живёт в файле, поэтому его видно обоим сторожам.
qbt_on_now() {
    rm -f /data/local/tmp/aria2/.qbt-resume-at
    if pidof qbittorrent-nox >/dev/null 2>&1; then
        log "команда «включить загрузки» — качалка и так работает"
    else
        start qbt 2>/dev/null
        log "команда «включить загрузки» — поднимаю качалку"
    fi
}

screen_key() {
    input keyevent "$1"
    sleep 2
    w=$(dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1 | cut -d= -f2)
    log "команда «$2» — экран: ${w:-?}"
}

while :; do
    if [ -f "$CTL/qbt-on" ]; then
        rm -f "$CTL/qbt-on"
        qbt_on_now
    fi
    if [ -f "$CTL/sleep" ]; then
        rm -f "$CTL/sleep"
        screen_key KEYCODE_SLEEP усыпить
    fi
    if [ -f "$CTL/wake" ]; then
        rm -f "$CTL/wake"
        screen_key KEYCODE_WAKEUP разбудить
    fi
    if [ -f "$CTL/reboot" ]; then
        rm -f "$CTL/reboot"; sync
        shutdown_gracefully reboot
    elif [ -f "$CTL/poweroff" ]; then
        rm -f "$CTL/poweroff"; sync
        shutdown_gracefully poweroff
    fi
    sleep 2
done
