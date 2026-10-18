#!/system/bin/sh
# Общие функции раскладки медиатеки. Подключается и хуком sort.sh, и миграцией migrate.sh.
# Оболочка mksh + toybox: без bash-измов, без curl/python/jq.

# MEDIA_ROOT можно переопределить снаружи — так гоняются тесты, не трогая настоящий диск.
HDD=${MEDIA_ROOT:-/mnt/media_rw/FA9E-9466}
DL=$HDD/Download
MOVIES=$HDD/Video/Movies
SHOWS=$HDD/Video/Shows
INBOX=$HDD/Разобрать
BIN=/data/local/tmp/aria2
LOG=${SORT_LOG:-$BIN/sort.log}
KEYFILE=$BIN/tmdb.key
VIDEO_RE='\.(mkv|mp4|avi|m4v|ts|m2ts|mov)$'
# Маркер серии в имени файла. Держим его ОДНОЙ переменной: раньше эта регулярка была
# переписана от руки в четырёх местах, и «Sherlock.s01ep01» не поймало ни одно из них.
# Форма «ep» после сезона встречается у релиз-групп наравне с «e» (18.09.2026).
SE_RE='[Ss][0-9][0-9]?[ ._x-]*[Ee][Pp]?[0-9][0-9]?'
SE_S_RE='^[Ss][0-9][0-9]?'
SE_E_RE='[Ee][Pp]?[0-9][0-9]?$'
JUNK_RE='([Ss]ample|[Tt]railer|трейлер|сэмпл|образец|/proof/|/subs/|/extras/|/screens|[Ss]creenshot)'
MIN_MB=50          # файл меньше — считаем мусором
MIN_SHARE=25       # и меньше этой доли от самого большого — тоже

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Процент-кодирование строки побайтно — безопасно для кириллицы и пробелов.
urlenc() {
  printf '%s' "$1" | od -An -tx1 | tr -s ' ' '\n' | grep -v '^$' \
    | awk '{ printf "%%%s", toupper($0) }'
}

# tmdb_lookup <movie|tv> <название> [год] -> печатает TMDB_ID=/TMDB_TITLE=/TMDB_YEAR=
tmdb_lookup() {
  kind=$1; q=$2; yr=$3
  [ -s "$KEYFILE" ] || return 1
  key=$(cat "$KEYFILE")
  extra=""
  [ -n "$yr" ] && [ "$kind" = movie ] && extra="&year=$yr"
  [ -n "$yr" ] && [ "$kind" = tv ] && extra="&first_air_date_year=$yr"
  out=$BIN/.tmdb.$$
  rm -f "$out" "$out.aria2"
  "$BIN/aria2c" --no-conf -q --check-certificate=false --max-tries=1 \
      --connect-timeout=10 --timeout=25 --retry-wait=0 --file-allocation=none \
      --allow-overwrite=true --auto-file-renaming=false \
      --dir="$BIN" --out=".tmdb.$$" \
      "https://api.themoviedb.org/3/search/$kind?api_key=$key&language=ru-RU&query=$(urlenc "$q")$extra" \
      >/dev/null 2>&1
  if [ ! -s "$out" ]; then rm -f "$out" "$out.aria2"; return 1; fi
  res=$(awk -f "$BIN/tmdb.awk" "$out")
  rm -f "$out" "$out.aria2"

  id=$(printf '%s\n' "$res" | sed -n 's/^TMDB_ID=//p')
  t=$(printf '%s\n' "$res" | sed -n 's/^TMDB_TITLE=//p')
  y=$(printf '%s\n' "$res" | sed -n 's/^TMDB_YEAR=//p')

  # Оригинальное название японского/китайского/корейского фильма — иероглифы
  # («君たちはどう生きるか»). Для папки это неудобно и людям, и в списке файлов,
  # поэтому в таком случае берём английское. Кириллицу не трогаем: русские
  # названия в каталоге читаются нормально.
  if [ -n "$id" ] && [ -n "$t" ] && has_cjk "$t"; then
    en=$(tmdb_en_title "$kind" "$id")
    if [ -n "$en" ]; then
      log "  оригинал иероглифами («$t») — беру английское «$en»"
      t=$en
    fi
  fi

  printf 'TMDB_ID=%s\nTMDB_TITLE=%s\nTMDB_YEAR=%s\n' "$id" "$t" "$y"
  return 0
}

# Есть ли в строке иероглифы (CJK). Смотрим первый байт UTF-8: E3..ED — это японский,
# китайский, корейский. Кириллица (D0/D1) и латиница сюда не попадают.
has_cjk() {
  printf '%s' "$1" | od -An -tx1 | tr -s ' ' '\n' | grep -qE '^e[3-9abcd]$'
}

# Английское название по id — вторым запросом, только когда оригинал оказался иероглифами.
tmdb_en_title() {
  key=$(cat "$KEYFILE")
  out=$BIN/.tmdben.$$
  rm -f "$out" "$out.aria2"
  "$BIN/aria2c" --no-conf -q --check-certificate=false --max-tries=1 \
      --connect-timeout=10 --timeout=25 --retry-wait=0 --file-allocation=none \
      --allow-overwrite=true --auto-file-renaming=false \
      --dir="$BIN" --out=".tmdben.$$" \
      "https://api.themoviedb.org/3/$1/$2?api_key=$key&language=en-US" >/dev/null 2>&1
  if [ -s "$out" ]; then
    # Ищем поле построчно нельзя: JSON в одну строку. И нельзя брать первое "name" —
    # раньше него в ответе лежит массив жанров, где у каждого жанра тоже есть "name"
    # (на этом я попался: у японского мультфильма вышло название «Animation»).
    # Поэтому сначала вырезаем массив жанров целиком.
    awk -v fld="$( [ "$1" = tv ] && echo name || echo title )" '
      { all = all $0 }
      END{
        gi = index(all, "\"genres\":[")
        if (gi > 0) {
          ge = index(substr(all, gi), "]")
          if (ge > 0) all = substr(all, 1, gi-1) substr(all, gi+ge)
        }
        pat = "\"" fld "\":\"[^\"]*\""
        if (match(all, pat)) {
          s = substr(all, RSTART, RLENGTH)
          sub(/^"[a-z_]+":"/, "", s); sub(/"$/, "", s)
          gsub(/\\\//, "/", s)
          print s
        }
      }' "$out"
  fi
  rm -f "$out" "$out.aria2"
}

# Убирает символы, запрещённые в именах на exFAT/Windows.
fsclean() {
  printf '%s' "$1" | sed -e 's| *: *| - |g' -e 's|[\\/*?"<>|]| |g' \
                         -e 's|  *| |g' -e 's|^[ .]*||' -e 's|[ .]*$||'
}

# Все видеофайлы внутри пути, по убыванию размера: "<МЕГАБАЙТЫ>\t<путь>".
# Именно мегабайты, а не байты: оболочка на этой приставке считает 32-битно и любой
# файл больше 4 ГБ в арифметике превращается в ноль. Делим через awk (там double).
videos_by_size() {
  find "$1" -type f 2>/dev/null | grep -aiE "$VIDEO_RE" | while IFS= read -r f; do
    sz=$(stat -c %s "$f" 2>/dev/null) || continue
    mb=$(printf '%s' "$sz" | awk '{ printf "%d", $1 / 1048576 }')
    printf '%s\t%s\n' "$mb" "$f"
  done | sort -rn
}

# Мусор ли: по имени или по размеру (в МБ) относительно самого большого файла.
is_junk() {
  f=$1; mb=$2; bigmb=$3
  echo "$f" | grep -aqE "$JUNK_RE" && return 0
  [ "$mb" -lt "$MIN_MB" ] && return 0
  [ "$bigmb" -gt 0 ] && [ $((mb * 100 / bigmb)) -lt "$MIN_SHARE" ] && return 0
  return 1
}

# Номера сезонов, вычитанные из ИМЁН ФАЙЛОВ внутри раздачи (по одному на строку,
# без повторов). Нужна там, где имя папки сезон не называет: parse.awk смотрит только
# на имя папки, и раздача «Better Call Saul» (без S01) опознавалась как фильм, а десять
# серий уезжали в «Разобрать» как сборник — так и вышло 08.09.2026.
# Маркер SxxExx в имени файла для фильмов не встречается, поэтому признак надёжный.
episode_marks() {
  find "$1" -type f 2>/dev/null | grep -aiE "$VIDEO_RE" | grep -avE "$JUNK_RE" \
    | while IFS= read -r f; do
        basename "$f" | grep -aoiE "$SE_RE" | head -1
      done \
    | grep -aoiE "$SE_S_RE" | tr -dc '0-9\n' | grep -v '^$' | sort -u
}

# Находит .torrent раздачи: имя раздачи лежит в bencode открытым текстом.
find_torrent() {
  name=$1
  for t in "$DL"/*.torrent; do
    [ -e "$t" ] || continue
    if grep -aqF "$name" "$t"; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# .nfo НЕ ПИШЕМ. Проверено 06.09.2026: файл .nfo с одной только ссылкой на TMDB
# питоновский скрапер Kodi 21 не понимает и молча ПРОПУСКАЕТ фильм целиком —
# «Дюна» не появлялась в медиатеке, пока файл не убрали. Полноценный XML-nfo тоже
# не годится: с ним Kodi берёт данные из файла и не идёт в сеть, то есть остаётся
# без постеров. Имя папки теперь и так точное («Dune (2021)»), по нему опознаётся
# надёжно и с картинками.
# Просит Kodi перечитать медиатеку. Без этого новый фильм появляется только после
# перезапуска приложения (в advancedsettings стоит updateonstartup): скачалось, а в Kodi
# пусто, пока не выйдешь и не зайдёшь.
#
# Два условия, на которых я споткнулся:
#  1) в настройках Kodi должны быть включены веб-интерфейс (порт 8090, потому что 8080
#     занят вебмордой качалки) и «управление от приложений на других системах» —
#     локальный адрес Kodi всё равно считает внешним клиентом;
#  2) команду надо посылать именно POST-ом. На GET через ссылку Kodi отвечает
#     «Bad client permission» — защита от запросов, подсунутых ссылкой. curl на приставке
#     нет, зато есть nc, поэтому собираем HTTP-запрос руками.
#  3) Kodi в фоне система замораживает: соединение он принимает и молчит. Без timeout
#     раскладка висела на nc и держала .sort.lock (10.10.2026, песочница).
kodi_rescan() {
  body='{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Scan"}'
  resp=$(printf 'POST /jsonrpc HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
           "${#body}" "$body" | timeout 15 nc 127.0.0.1 8090 2>/dev/null | tail -1)
  case "$resp" in
    *'"result"'*) log "  Kodi: медиатека обновляется" ;;
    *)            log "  Kodi не ответил (закрыт?) — фильм появится при следующем запуске" ;;
  esac
}
