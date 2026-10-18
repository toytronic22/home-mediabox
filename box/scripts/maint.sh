#!/system/bin/sh
# Обслуживание приставки. Две задачи, обе раньше делались руками:
#
#  1) Раз в неделю складывает резервную копию настроек на винчестер. Раньше копии жили только
#     на маке — а после истории с перепрошивкой понятно, что копия должна лежать и рядом.
#     Кладём на диск: он переживает и перепрошивку, и смену приставки, и его видно в вебморде.
#     Копия одна и перезаписывается — история не копится. Чтобы сбой посреди упаковки не оставил
#     совсем без копии, пишем во временный файл и подменяем старую только после успеха.
#  2) Раз в сутки просит Kodi выкинуть из медиатеки записи о пропавших файлах. Нужно потому,
#     что фильмы теперь можно удалять через файловый менеджер, а Kodi об этом не узнаёт и
#     оставляет карточку без файла.

BIN=/data/local/tmp/aria2
# Общие функции — журнал, обращение к качалке и к Kodi, ротация, проверка диска.
# Вынесены в один файл 14.09.2026: до этого копии жили в девяти скриптах и расходились
# в мелочах (обрезка заголовков HTTP, таймауты), из-за чего работали по случайности.
. /data/local/tmp/aria2/lib.sh
kodi_cmd()   { kodi_rpc "$1"; }
rotate_log() { rotate_one "$LOG" 102400 200; }

HDD=/mnt/media_rw/FA9E-9466
BACKUP=$HDD/Backup
KODI=/data/media/0/Android/data/org.xbmc.kodi/files/.kodi
OVERLAY_CFG=/data/media/0/Android/data/ru.alexey.ariaoverlay/files/config.properties
LOG=$BIN/maint.log
# Папка бота в Termux: сюда кладём пароли для копии в гит (см. save_secrets)
SECRETS=/data/data/com.termux/files/home/bot/secrets

PERIOD=3600           # как часто просыпаться
BACKUP_EVERY=604800   # копия — раз в неделю
CLEAN_EVERY=86400     # чистка медиатеки — раз в сутки



# Диск могли унести к компьютеру. Тогда обе задачи опасны или бессмысленны.

# Прошло ли достаточно времени с прошлого раза (метка — файл, его mtime)
due() {
    stamp=$1; every=$2
    [ -f "$stamp" ] || return 0
    last=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - last)) -ge "$every" ]
}

# Kodi принимает изменяющие команды только POST-ом: на GET отвечает «Bad client permission».
# curl на приставке нет, поэтому запрос собираем руками через nc.

do_backup() {
    if ! disk_ready; then log "копия отложена: диск не подключён"; return 1; fi
    mkdir -p "$BACKUP" 2>/dev/null
    tmp=$BIN/.bk.$$
    rm -rf "$tmp"
    mkdir -p "$tmp/aria2" "$tmp/kodi" "$tmp/system"

    # качалка: скрипты, конфиг, ключ и список задач. Логи не берём — они не нужны для восстановления.
    for f in "$BIN"/*.sh "$BIN"/*.awk "$BIN"/aria2.conf "$BIN"/tmdb.key "$BIN"/aria2.session; do
        [ -f "$f" ] && cp -f "$f" "$tmp/aria2/" 2>/dev/null
    done
    [ -f "$OVERLAY_CFG" ] && cp -f "$OVERLAY_CFG" "$tmp/aria2/ariaoverlay-config.properties" 2>/dev/null

    # qBittorrent (качалка с 09.09.2026): настройки и список задач. Сам бинарник
    # не берём — он 62 МБ и лежит в ~/ugoos-tools/qbittorrent на маке.
    mkdir -p "$tmp/qbt" 2>/dev/null
    cp -f /data/local/tmp/qbt/profile/qBittorrent/config/qBittorrent.conf "$tmp/qbt/" 2>/dev/null
    cp -f /data/local/tmp/qbt/profile/qBittorrent/data/BT_backup/*.fastresume "$tmp/qbt/" 2>/dev/null
    cp -f /data/local/tmp/qbt/profile/qBittorrent/data/BT_backup/*.torrent "$tmp/qbt/" 2>/dev/null

    # Kodi: база с отметками о просмотре и настройки. Номер базы меняется с большой версией
    # Kodi (21 — MyVideos131, 22 — MyVideos149), старая остаётся рядом — берём самую свежую.
    db=$(ls -t "$KODI/userdata/Database"/MyVideos[0-9]*.db 2>/dev/null | head -1)
    if [ -n "$db" ]; then cp -f "$db" "$tmp/kodi/" 2>/dev/null
    else log "в копию не попала база просмотров Kodi: файла MyVideos*.db нет"; fi
    # ВНИМАНИЕ: passwords.xml в архив НЕ берём — в нём пароли к сетевым папкам открытым текстом,
    # а готовый архив лежит на медиадиске, который файловый сервер раздаёт всей домашней сети
    # без пароля. Он уходит в гит мимо диска, через папку бота (save_secrets).
    for x in "$KODI/userdata"/*.xml; do
        case "$(basename "$x")" in passwords.xml) continue ;; esac
        cp -f "$x" "$tmp/kodi/" 2>/dev/null
    done

    # системное: автозапуск, адреса TMDB, список установленного
    cp -f /system/etc/init/aria2.rc "$tmp/system/" 2>/dev/null
    cp -f /system/etc/init/videoraw.rc "$tmp/system/" 2>/dev/null
    cp -f /system/etc/hosts "$tmp/system/" 2>/dev/null
    pm list packages -3 2>/dev/null | cut -d: -f2 > "$tmp/system/apps.txt"

    save_secrets

    # пишем рядом и подменяем одним движением: пока новая не готова, старая на месте
    if tar czf "$BACKUP/.ugoos-backup.new" -C "$tmp" . 2>/dev/null; then
        mv -f "$BACKUP/.ugoos-backup.new" "$BACKUP/ugoos-backup.tgz"
        # init запускает службы с umask 077: архив выходит 600 от root, а файловый сервер работает
        # от shell — и бот получает 500 вместо копии. Паролей в архиве нет (они идут мимо диска).
        chmod 644 "$BACKUP/ugoos-backup.tgz" 2>/dev/null
        sz=$(stat -c %s "$BACKUP/ugoos-backup.tgz" 2>/dev/null || echo 0)
        log "копия обновлена: ugoos-backup.tgz ($((sz/1024)) КБ, база Kodi: $(basename "${db:-нет}"))"
    else
        rm -f "$BACKUP/.ugoos-backup.new"
        log "копию создать не удалось — прежняя осталась на месте"
    fi
    rm -rf "$tmp"
}

# Пароли и токены — не в архив: архив лежит на диске, который файловый сервер раздаёт всей
# сети без пароля. Кладём их в закрытую папку бота в Termux, оттуда бот отправит их в закрытый
# репозиторий вместе с копией (box/bot/gitbackup.py). Здесь — то, что видно только root:
# пароли сетевых папок Kodi, настройки дополнений Kodi (в них входы в сервисы), пароли Wi-Fi.
save_secrets() {
    s=$SECRETS.new
    rm -rf "$s"
    mkdir -p "$s/kodi-addons"
    cp -f "$KODI/userdata/passwords.xml" "$s/kodi-passwords.xml" 2>/dev/null
    for x in "$KODI/userdata/addon_data"/*/settings.xml; do
        [ -f "$x" ] && cp -f "$x" "$s/kodi-addons/$(basename "$(dirname "$x")").xml" 2>/dev/null
    done
    for w in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml; do
        [ -f "$w" ] && { cp -f "$w" "$s/wifi.xml" 2>/dev/null; break; }
    done
    n=$(find "$s" -type f | wc -l)
    # Хозяин и метка SELinux — как у папки бота, иначе бот их не прочтёт. Не через run-as:
    # он падает, когда его зовёт служба без дополнительных групп (наша maint как раз такая).
    home=${SECRETS%/*}
    if err=$( { chown -R "$(stat -c %u:%g "$home")" "$s" && chmod -R go-rwx "$s" \
            && chcon -R "$(stat -c %C "$home")" "$s" && rm -rf "$SECRETS" && mv "$s" "$SECRETS"; } 2>&1 ); then
        log "пароли для копии в гит: $n файлов в папке бота"
    else
        log "пароли для копии в гит не легли в папку бота ($err) — в гит уйдёт копия без них"
    fi
    rm -rf "$s"
}

do_clean() {
    # ВАЖНО: без диска Kodi при чистке решит, что пропали ВСЕ файлы, и сотрёт медиатеку целиком.
    # Ровно поэтому в advancedsettings.xml выключен cleanonupdate, а чистим только вручную и с проверкой.
    if ! disk_ready; then log "чистка отменена: диска нет, Kodi стёр бы всю медиатеку"; return 1; fi
    r=$(kodi_cmd '{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Clean","params":{"showdialogs":false}}')
    case "$r" in
        *'"result"'*) log "Kodi чистит медиатеку от пропавших файлов" ;;
        *)            log "Kodi не ответил (закрыт?) — чистку отложил" ;;
    esac
}


# Защита от переполнения диска: когда места совсем мало, качалка не может дописать
# файл, начинает сыпать ошибками и упирается в диск — а вместе с ней тормозит вся
# приставка. Поэтому при остатке меньше порога ставим закачки на паузу: скачанное
# цело, продолжить можно в любой момент, освободив место.
LOW_GB=15

# Защита от переполнения переписана 14.09.2026 под qBittorrent. До этого она обращалась к aria2
# по порту 6800 — а её заменили 09.09, то есть защиты не было вовсе пять дней. Теперь спрашиваем
# качалку по её API и ставим раздачи на паузу: скачанное цело, продолжить можно, освободив место.

low_space() {
    disk_ready || return 0
    free_gb=$(df -k "$HDD" 2>/dev/null | tail -1 | awk '{printf "%d", $4/1048576}')
    [ -z "$free_gb" ] && return 0
    [ "$free_gb" -gt "$LOW_GB" ] && return 0
    # считаем только то, что реально качается или ждёт очереди
    active=$(qbt_get "torrents/info?filter=downloading" | grep -o '"hash":"' | wc -l)
    queued=$(qbt_get "torrents/info?filter=stalled_downloading" | grep -o '"hash":"' | wc -l)
    n=$((active + queued))
    if [ "$n" -gt 0 ]; then
        log "на диске осталось ${free_gb} ГБ — ставлю $n раздач на паузу, чтобы не забить его под ноль"
        qbt_post torrents/stop "hashes=all" >/dev/null
    fi
}

# после загрузки даём системе прийти в себя
sleep 180
log "обслуживание запущено (проверка раз в ${PERIOD}с)"

while :; do
    rotate_log
    low_space
    if due "$BIN/.last_backup" "$BACKUP_EVERY"; then
        do_backup && touch "$BIN/.last_backup"
    fi
    if due "$BIN/.last_clean" "$CLEAN_EVERY"; then
        do_clean && touch "$BIN/.last_clean"
    fi
    sleep "$PERIOD"
done
