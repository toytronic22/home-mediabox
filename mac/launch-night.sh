#!/bin/bash
# Ночной запуск закачки: сторож → раздачи → наблюдатель → 3 минуты контроля.
# Использование: launch-night.sh <потолок сторожа, напр. 6M|12M>
LIM=${1:?потолок, например 6M}
BOX=192.168.1.10
adb shell "sed -i 's/^WIRE_LIMIT=[0-9]*M;/WIRE_LIMIT=$LIM;/' /data/local/tmp/aria2/ariaguard.sh; grep -n '^WIRE_LIMIT' /data/local/tmp/aria2/ariaguard.sh"
sed -i '' "s/^WIRE_LIMIT=[0-9]*M;/WIRE_LIMIT=$LIM;/" ~/ugoos-tools/qbittorrent/ariaguard.sh
adb shell 'start ariaguard; sleep 2; echo "ariaguard=$(getprop init.svc.ariaguard) diskbreath=$(getprop init.svc.diskbreath)"'
echo "жду первый проход сторожа (он выставит потолок)…"; sleep 75
adb shell 'tail -3 /data/local/tmp/aria2/ariaguard.log'
curl -s -m 8 "http://$BOX:8080/api/v2/app/preferences" | python3 -c 'import sys,json; p=json.load(sys.stdin); print("качалка: лимит %.0f МБ/с, активных закачек %d" % (p["dl_limit"]/1048576, p["max_active_downloads"]))'
curl -s -m 8 -X POST "http://$BOX:8080/api/v2/torrents/start" -d 'hashes=all' -o /dev/null -w 'старт раздач: HTTP %{http_code}\n'
adb shell 'nohup setsid sh /data/local/tmp/aria2/nightwatch.sh >/dev/null 2>&1 & exit 0'
sleep 2; adb shell 'ps -A -o pid,args | grep "[n]ightwatch" | head -1 | awk "{print \"наблюдатель запущен, pid\", \$1}"'
echo "=== контроль 3 минуты:"
for i in 1 2 3 4 5 6; do
  adb shell 'a=$(cat /sys/block/sda/stat); sleep 30; b=$(cat /sys/block/sda/stat); echo "$a $b" | awk -v d="$(awk "/^Dirty:/{printf \"%d\",\$2/1024}" /proc/meminfo)" -v now="$(date +%T)" '"'"'{n=NF/2; for(i=1;i<=n;i++) x[i]=$(i+n)-$i; printf "  [%s] диск: запись %.1f МБ/с (лат. %.0f мс), чтение %.1f, занят %.0f%%, грязных %s МБ", now, x[7]*512/30/1048576, (x[5]?x[8]/x[5]:0), x[3]*512/30/1048576, x[10]/300, d}'"'"''
  curl -s -m 8 "http://$BOX:8080/api/v2/sync/maindata" | python3 -c 'import sys,json; d=json.load(sys.stdin); s=d["server_state"]; ts=d.get("torrents",{}); a=[t for t in ts.values() if t["state"] in ("downloading","forcedDL")]; a=a[0] if a else None; print(" | сеть %.1f МБ/с, очередь %.1f МБ, перегруз=%s%s" % (s["dl_info_speed"]/1048576, s["total_queued_size"]/1048576, s["write_cache_overload"], (" | %s %.1f%% сиды %d/%d" % (a["name"][:30], a["progress"]*100, a["num_seeds"], a["num_complete"])) if a else " | нет активной"))'
done
