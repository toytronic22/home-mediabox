#!/bin/zsh
# Возвращает наши правки в /system после прошивки или обновления приставки.
#
# Зачем нужен: файл автозапуска наших служб и адреса TMDB живут в /system,
# а он перезаписывается при каждом обновлении. Правки наносятся через
# `adb remount` (overlayfs), поэтому переживают перезагрузки, но не обновления.
#
# ВАЖНО: overlayfs ломает установку обновлений системы — update_engine
# отказывается работать и падает с kInstallDeviceOpenError. Перед тем как
# обновлять приставку, сначала снять его:
#     adb -s $TV enable-verity && adb -s $TV reboot
# и уже потом ставить обновление, а этим скриптом вернуть правки обратно.

set -u
# Кабель (.85) или Wi-Fi (.83) — берём живой адрес, кабель предпочтительнее.
if [[ -z "${TV:-}" ]]; then
  TV="192.168.1.10:5555"
  for ip in 192.168.1.10 192.168.1.11; do
    if ping -c 1 -W 1000 "$ip" >/dev/null 2>&1; then TV="$ip:5555"; break; fi
  done
fi
B="${1:-}"

if [[ -z "$B" ]]; then
  # Самая свежая папка — по времени изменения, не по алфавиту: по алфавиту выигрывала
  # backup-before-qbt без init/, и после прошивки диск остался бы без монтировщика.
  B=$(ls -dt ~/ugoos-tools/backup-*/ 2>/dev/null | head -1); B=${B%/}
fi
if [[ ! -d "$B/init" ]]; then
  echo "не нашёл резервную копию: укажите путь первым аргументом"
  exit 1
fi
echo "беру файлы из: $B"

adb connect "$TV" >/dev/null 2>&1
adb -s "$TV" root >/dev/null 2>&1
sleep 4
adb connect "$TV" >/dev/null 2>&1
sleep 2

echo "== открываю /system на запись =="
adb -s "$TV" remount 2>&1 | tail -2

echo "== возвращаю файлы =="
for f in aria2.rc videoraw.rc; do
  if [[ -f "$B/init/$f" ]]; then
    adb -s "$TV" push "$B/init/$f" "/system/etc/init/$f" >/dev/null 2>&1 \
      && echo "  /system/etc/init/$f" || echo "  НЕ вышло: $f"
  fi
done
if [[ -f "$B/system/hosts" ]]; then
  adb -s "$TV" push "$B/system/hosts" /system/etc/hosts >/dev/null 2>&1 \
    && echo "  /system/etc/hosts (адреса TMDB)" || echo "  НЕ вышло: hosts"
fi

# Резолвер для qBittorrent. Статическая сборка не умеет читать DNS Android и без
# этого файла не находит ни одного трекера («Host not found»). Появился 09.09.2026
# вместе с переездом на qBittorrent.
adb -s "$TV" shell 'printf "nameserver 192.168.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n" > /system/etc/resolv.conf && chmod 644 /system/etc/resolv.conf' >/dev/null 2>&1 \
  && echo "  /system/etc/resolv.conf (DNS для качалки)" || echo "  НЕ вышло: resolv.conf"

echo "== проверяю, что рабочая папка цела =="
adb -s "$TV" shell "ls /data/local/tmp/aria2/ 2>/dev/null | wc -l" | tr -d '\r' \
  | xargs -I{} echo "  файлов в /data/local/tmp/aria2: {}"

echo "== перезагружаю, чтобы init подхватил службы =="
adb -s "$TV" reboot
echo "жду возвращения…"
# adb на уже открытое соединение отвечает "already connected", поэтому ждать
# ровно "connected" нельзя — цикл повиснет навсегда. Ждём любой из двух ответов.
until adb connect "$TV" 2>/dev/null | grep -qE "^(connected|already connected)"; do sleep 5; done
sleep 25

echo "== службы =="
adb -s "$TV" shell 'for s in qbt fileweb dlwatch maint health videoraw ariaguard; do printf "%-11s %s\n" $s $(getprop init.svc.$s); done'
echo "== диск =="
adb -s "$TV" shell "df -h /storage/FA9E-9466 2>/dev/null | tail -1"
echo "готово"
