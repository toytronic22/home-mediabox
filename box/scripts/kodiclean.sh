#!/system/bin/sh
# Убирает из медиатеки Kodi записи о файлах, которых больше нет на диске.
# Нужен потому, что штатная автоочистка выключена: с ней Kodi стирает всю
# медиатеку, если стартанул без подключённого винчестера.
DB=$(ls -t /data/media/0/Android/data/org.xbmc.kodi/files/.kodi/userdata/Database/MyVideos[0-9]*.db 2>/dev/null | head -1)
[ -f "$DB" ] || { echo "база медиатеки Kodi не найдена"; exit 0; }
sqlite3 "$DB" "SELECT idFile, p.strPath || f.strFilename FROM files f JOIN path p ON f.idPath=p.idPath;" \
| while IFS='|' read -r id path; do
    real=$(printf '%s' "$path" | sed 's|^/storage/FA9E-9466|/mnt/media_rw/FA9E-9466|')
    [ -e "$real" ] && continue
    sqlite3 "$DB" "DELETE FROM movie WHERE idFile=$id; DELETE FROM episode WHERE idFile=$id; DELETE FROM files WHERE idFile=$id;"
    echo "убрано из медиатеки: $(basename "$path")"
done
# сериалы без серий и пустые папки на диске
sqlite3 "$DB" "DELETE FROM tvshow WHERE idShow NOT IN (SELECT DISTINCT idShow FROM episode);" 2>/dev/null
find /mnt/media_rw/FA9E-9466/Video -mindepth 1 -type d -empty -delete 2>/dev/null
exit 0
