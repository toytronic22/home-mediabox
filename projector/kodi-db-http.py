#!/usr/bin/env python3
"""Переписывает пути в копии медиатеки Kodi для проектора: диск приставки → http с dufs.

Медиатека на проекторе — копия базы с приставки, и пути в ней — диск приставки
(/storage/FA9E-9466/…). Подмена путей в advancedsettings.xml тут не помогает: Kodi
подставляет адрес как есть, с пробелами, а libcurl отвергает такой адрес ещё до запроса
(«URL using bad/illegal format», код 3) — и по http://, и по dav://. Закодированный адрес
играет. Поэтому пути в базе переписываем сразу в закодированном виде.

Повторный запуск безопасен: трогаются только пути с диска приставки. Строки, которые
Kodi завёл, когда фильм открывали прямой ссылкой, сливаются с медиатекой: место, где
остановились, переходит к фильму, а лишние строки удаляются.

Запуск — при закрытом Kodi на проекторе:
    jmgo shell 'am force-stop org.xbmc.kodi'
    jmgo adb pull /sdcard/kodi_data/.kodi/userdata/Database/MyVideos149.db /tmp/kodi.db
    python3 projector/kodi-db-http.py /tmp/kodi.db
    jmgo adb push /tmp/kodi.db /sdcard/kodi_data/.kodi/userdata/Database/MyVideos149.db
"""
import sqlite3
import sys
import urllib.parse

DISK = "/storage/FA9E-9466/"
HTTP = "http://192.168.1.10:8777/"
# Что можно оставить в адресе как есть. Пробел, %, #, ?, | (у Kodi это разделитель
# параметров) и всё не-ASCII кодируется.
SAFE = "/()!'-._~,;=&+@$*:"
FILE_TABLES = ("bookmark", "settings", "streamdetails", "stacktimes")


def to_http(path):
    return HTTP + urllib.parse.quote(path[len(DISK):], safe=SAFE)


def main(db):
    c = sqlite3.connect(db)
    paths = c.execute("SELECT idPath, strPath FROM path WHERE strPath LIKE ?", (DISK + "%",)).fetchall()
    merged = 0
    for id_path, old in paths:
        new = to_http(old)
        for (dup,) in c.execute("SELECT idPath FROM path WHERE strPath = ? AND idPath != ?", (new, id_path)).fetchall():
            for dup_file, name in c.execute("SELECT idFile, strFilename FROM files WHERE idPath = ?", (dup,)).fetchall():
                own = c.execute("SELECT idFile FROM files WHERE idPath = ? AND strFilename IN (?, ?)",
                                (id_path, name, urllib.parse.unquote(name))).fetchone()
                if own and not c.execute("SELECT 1 FROM bookmark WHERE idFile = ?", own).fetchone():
                    c.execute("UPDATE bookmark SET idFile = ? WHERE idFile = ?", (own[0], dup_file))
                for t in FILE_TABLES:
                    c.execute(f"DELETE FROM {t} WHERE idFile = ?", (dup_file,))
                c.execute("DELETE FROM files WHERE idFile = ?", (dup_file,))
            c.execute("DELETE FROM path WHERE idPath = ?", (dup,))
            merged += 1
        c.execute("UPDATE path SET strPath = ? WHERE idPath = ?", (new, id_path))
        for id_file, name in c.execute("SELECT idFile, strFilename FROM files WHERE idPath = ?", (id_path,)).fetchall():
            if "://" not in name:
                c.execute("UPDATE files SET strFilename = ? WHERE idFile = ?",
                          (urllib.parse.quote(name, safe=SAFE), id_file))

    full = {"movie": "c22", "episode": "c18", "musicvideo": "c13"}
    items = 0
    for table, col in full.items():
        for rowid, old in c.execute(f"SELECT rowid, {col} FROM {table} WHERE {col} LIKE ?", (DISK + "%",)).fetchall():
            c.execute(f"UPDATE {table} SET {col} = ? WHERE rowid = ?", (to_http(old), rowid))
            items += 1

    # Прямые ссылки с пробелами Kodi не открыл, но строки завёл: в медиатеке их нет, удаляем
    broken = 0
    for (id_path,) in c.execute("SELECT idPath FROM path WHERE strPath LIKE ? AND strPath LIKE '% %'",
                                (HTTP + "%",)).fetchall():
        files = [f for (f,) in c.execute("SELECT idFile FROM files WHERE idPath = ?", (id_path,))]
        if any(c.execute(f"SELECT 1 FROM {t} WHERE idFile = ?", (f,)).fetchone()
               for t in ("movie", "episode", "musicvideo") for f in files):
            continue
        for f in files:
            for t in FILE_TABLES:
                c.execute(f"DELETE FROM {t} WHERE idFile = ?", (f,))
            c.execute("DELETE FROM files WHERE idFile = ?", (f,))
        c.execute("DELETE FROM path WHERE idPath = ?", (id_path,))
        broken += 1

    c.commit()
    left = c.execute("SELECT count(*) FROM path WHERE strPath LIKE ?", (DISK + "%",)).fetchone()[0]
    print(f"папок переписано: {len(paths)}, фильмов и серий: {items}, слито строк прямых ссылок: {merged}, битых убрано: {broken}, "
          f"осталось путей с диска: {left}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("нужен путь к MyVideos*.db")
    main(sys.argv[1])
