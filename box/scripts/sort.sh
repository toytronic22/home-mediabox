#!/system/bin/sh
# Хук aria2 on-download-complete. Аргументы: $1=gid $2=число_файлов $3=путь_первого_файла
# Раскладывает скачанное в медиатеку:
#   Movies/<Оригинальное название (Год)>/<то же имя>.mkv + .torrent + .nfo
#   Shows/<Оригинальное название>/Season NN/<Название> SNNEMM.mkv + .torrent, tvshow.nfo в корне
# Оригинальное название и номер в базе берутся из TMDB по русскому названию из раздачи.
# Что не опознали — уезжает в «Разобрать», ничего не удаляется молча.
. /data/local/tmp/aria2/medialib.sh

FIRST="$3"
[ -z "$FIRST" ] && exit 0                       # служебная задача метаданных magnet
case "$FIRST" in "$DL"/*) ;; *) exit 0 ;; esac

REL=${FIRST#"$DL"/}
TOP=${REL%%/*}
SRCPATH="$DL/$TOP"
[ -e "$SRCPATH" ] || exit 0
case "$TOP" in *.torrent) exit 0 ;; esac   # .aria2 больше не бывает: качалку сменили 09.09.2026

exec 9>"$BIN/.sort.lock"; flock 9 2>/dev/null   # два хука сразу не топчутся

# ---------------------------------------------------------------- разбор имени
eval "$(printf '%s\n' "$TOP" | awk -f "$BIN/parse.awk" | grep -E '^(TYPE|TITLE_RU|TITLE_EN|YEAR|SEASON)=' | sed 's/^\([A-Z_]*\)=\(.*\)$/\1="\2"/')"
[ -z "$TITLE_RU" ] && TITLE_RU="$TOP"
log "начало: «$TOP» -> тип=$TYPE название=«$TITLE_RU» год=${YEAR:-—} сезон=${SEASON:-—}"

# Имя папки — не единственный источник правды: у раздачи может не быть ни «S01», ни
# «сезон 1» («Better Call Saul» на десять серий). Тогда тип выходил movie, а дальше
# несколько полноразмерных файлов считались сборником и уезжали в «Разобрать».
# Заглядываем в имена файлов ДО запроса в базу — иначе название спросим не про сериал.
if [ "$TYPE" != show ]; then
    MARKS=$(episode_marks "$SRCPATH")
    if [ -n "$MARKS" ]; then
        TYPE=show
        [ -z "$SEASON" ] && SEASON=$(printf '%s\n' "$MARKS" | head -1)
        log "  по имени вышел фильм, но в файлах есть номера серий (сезон(ы): $(printf '%s' "$MARKS" | tr '\n' ' ')) — считаю сериалом"
    fi
fi

# ------------------------------------------------------- оригинальное название
KIND=movie; [ "$TYPE" = show ] && KIND=tv
TMDB_ID=""; TMDB_TITLE=""; TMDB_YEAR=""
eval "$(tmdb_lookup "$KIND" "$TITLE_RU" "$YEAR" | sed 's/^\([A-Z_]*\)=\(.*\)$/\1="\2"/')" 2>/dev/null
if [ -z "$TMDB_TITLE" ] && [ -n "$TITLE_EN" ]; then
    eval "$(tmdb_lookup "$KIND" "$TITLE_EN" "$YEAR" | sed 's/^\([A-Z_]*\)=\(.*\)$/\1="\2"/')" 2>/dev/null
fi
if [ -n "$TMDB_TITLE" ]; then
    NAME=$(fsclean "$TMDB_TITLE")
    [ -z "$YEAR" ] && YEAR="$TMDB_YEAR"
    log "  база фильмов: «$TMDB_TITLE» id=$TMDB_ID год=$TMDB_YEAR"
else
    NAME=$(fsclean "${TITLE_EN:-$TITLE_RU}")
    log "  база фильмов не ответила или не нашла — беру название из раздачи: «$NAME»"
fi
[ -z "$NAME" ] && NAME=$(fsclean "$TOP")

# ------------------------------------------------------------- отбор видеофайлов
TMP=$BIN/.sort.$$; : > "$TMP"
# Временный файл снимаем в любом случае. Раньше это делалось только на одной ветке, и при
# уже уехавшей папке раздачи он оставался навсегда — накопилось десять штук.
trap 'rm -f "$TMP"' EXIT
videos_by_size "$SRCPATH" > "$TMP"
if [ ! -s "$TMP" ]; then
    log "  видеофайлов нет — в «Разобрать»"
    mkdir -p "$INBOX"; mv -f "$SRCPATH" "$INBOX/" 2>/dev/null
    rm -f "$TMP"; exit 0
fi
BIG=$(head -1 "$TMP" | cut -f1)
KEEP=$BIN/.keep.$$; : > "$KEEP"
DROPPED=0
while IFS="$(printf '\t')" read -r sz f; do
    if is_junk "$f" "$sz" "$BIG"; then DROPPED=$((DROPPED+1)); continue; fi
    printf '%s\t%s\n' "$sz" "$f" >> "$KEEP"
done < "$TMP"
[ "$DROPPED" -gt 0 ] && log "  отсеяно как мусор: $DROPPED файл(ов)"
if [ ! -s "$KEEP" ]; then
    log "  после отсева ничего не осталось — в «Разобрать»"
    mkdir -p "$INBOX"; mv -f "$SRCPATH" "$INBOX/"; rm -f "$TMP" "$KEEP"; exit 0
fi

TORRENT=$(find_torrent "$TOP")

# ------------------------------------------------------------------- раскладка
if [ "$TYPE" = show ]; then
    SHOWDIR="$SHOWS/$NAME"
    mkdir -p "$SHOWDIR"
    moved=0
    while IFS="$(printf '\t')" read -r sz f; do
        base=$(basename "$f"); ext=${base##*.}
        se=$(printf '%s' "$base" | grep -aoiE "$SE_RE" | head -1)
        s=""; e=""
        if [ -n "$se" ]; then
            s=$(printf '%s' "$se" | grep -aoiE "$SE_S_RE" | tr -dc '0-9')
            e=$(printf '%s' "$se" | grep -aoiE "$SE_E_RE" | tr -dc '0-9')
        fi
        # Маркер нашёлся, а номер из него не вычитался — такое бывает на непривычной
        # форме записи. Пустая строка ниже уходит в $((10#$e)) и роняет раскладку,
        # поэтому подставляем те же запасные номера, что и при полном отсутствии маркера.
        [ -z "$s" ] && s=${SEASON:-1}
        [ -z "$e" ] && e=$((moved+1))
        s=$(printf '%02d' "$((10#$s))"); e=$(printf '%02d' "$((10#$e))")
        SEASONDIR="$SHOWDIR/Season $s"
        mkdir -p "$SEASONDIR"
        dest="$SEASONDIR/$NAME S${s}E${e}.$ext"
        if [ -e "$dest" ]; then log "  уже есть, пропускаю: $NAME S${s}E${e}"; continue; fi
        mv -f "$f" "$dest" && moved=$((moved+1))
        LASTSEASON="$SEASONDIR"
    done < "$KEEP"
    if [ -n "$TORRENT" ] && [ -n "$LASTSEASON" ]; then
        cp -f "$TORRENT" "$LASTSEASON/$NAME S${SEASON:-01}.torrent" 2>/dev/null && rm -f "$TORRENT"
    fi
    log "  готово: сериал «$NAME», перенесено серий: $moved"
    kodi_rescan
else
    COUNT=$(wc -l < "$KEEP")
    if [ "$COUNT" -gt 1 ]; then
        log "  несколько полноразмерных фильмов ($COUNT) — это сборник, в «Разобрать»"
        mkdir -p "$INBOX"; mv -f "$SRCPATH" "$INBOX/"; rm -f "$TMP" "$KEEP"; exit 0
    fi
    FOLDER="$NAME"; [ -n "$YEAR" ] && FOLDER="$NAME ($YEAR)"
    DEST="$MOVIES/$FOLDER"
    mkdir -p "$DEST"
    f=$(cut -f2 "$KEEP" | head -1)
    ext=$(basename "$f"); ext=${ext##*.}
    if [ -e "$DEST/$FOLDER.$ext" ]; then
        log "  уже есть, пропускаю: $FOLDER"
    else
        mv -f "$f" "$DEST/$FOLDER.$ext"
    fi
    [ -n "$TORRENT" ] && { cp -f "$TORRENT" "$DEST/$FOLDER.torrent" && rm -f "$TORRENT"; }
    log "  готово: фильм «$FOLDER»"
    kodi_rescan
fi

# --------------------------------------------------------------------- уборка
rm -f "$KEEP"
# чужие .nfo от релиз-групп сбивают опознание Kodi
find "$SRCPATH" -type f -iname '*.nfo' -delete 2>/dev/null
# остатки раздачи: если видео не осталось — сносим, иначе отправляем разбираться
if [ -d "$SRCPATH" ]; then
    # остались ли ГОДНЫЕ видеофайлы? одни сэмплы и трейлеры — просто мусор, сносим
    LEFT=0
    videos_by_size "$SRCPATH" > "$TMP" 2>/dev/null
    if [ -s "$TMP" ]; then
        LB=$(head -1 "$TMP" | cut -f1)
        while IFS="$(printf '\t')" read -r mb f; do
            is_junk "$f" "$mb" "$LB" || LEFT=$((LEFT+1))
        done < "$TMP"
    fi
    rm -f "$TMP"
    if [ "$LEFT" -eq 0 ]; then
        rm -rf "$SRCPATH"
    else
        mkdir -p "$INBOX"; mv -f "$SRCPATH" "$INBOX/" 2>/dev/null
        log "  в раздаче осталось ещё $LEFT видео — папка ушла в «Разобрать»"
    fi
fi
exit 0
