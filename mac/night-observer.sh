#!/bin/bash
# Наружный ночной наблюдатель за приставкой (с мака), до 07:00: раз в минуту ping,
# аптайм через adb (ловит перезагрузки), скорость качалки, флаг перегруза диска и
# сиды активной раздачи. Нужен, чтобы отличить «приставка перезагрузилась» от
# «висит с живым ядром» от «всё шло, но медленно» — и в последнем случае понять,
# сеть это или диск. Если мак заснёт (закрытая крышка) — лог оборвётся;
# приставочный night.log останется.
BOX=192.168.1.10
LOG=~/ugoos-tools/night-$(date +%F).log
END_H=7

tmo() { local t=$1; shift; "$@" & local pid=$!; ( sleep "$t"; kill $pid 2>/dev/null ) & local w=$!; wait $pid 2>/dev/null; local rc=$?; kill $w 2>/dev/null; wait $w 2>/dev/null; return $rc; }

echo "# время | ping мс | аптайм с | сеть вниз МБ/с | очередь диска МБ, перегруз | активная: %, сиды подкл/в рое, состояние | состояния | заметка" >> "$LOG"
echo "$(date '+%F %T') наблюдение начато" >> "$LOG"
prev_up=""
while :; do
    h=$(date +%H); h=${h#0}
    if [ "${h:-0}" -ge $END_H ] && [ "${h:-0}" -lt 12 ]; then echo "$(date '+%F %T') наблюдение окончено (07:00)" >> "$LOG"; exit 0; fi
    now=$(date '+%F %T')
    p=$(ping -c 1 -W 2000 $BOX 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); [ -z "$p" ] && p="НЕТ ПИНГА"
    up=$(tmo 20 adb -s $BOX:5555 shell cut -d. -f1 /proc/uptime 2>/dev/null | tr -d '\r\n'); [ -z "$up" ] && up="adb НЕТ"
    note=""
    if [[ "$up" =~ ^[0-9]+$ && "$prev_up" =~ ^[0-9]+$ && "$up" -lt "$prev_up" ]]; then note="ПЕРЕЗАГРУЗКА (аптайм $prev_up → $up)"; fi
    [[ "$up" =~ ^[0-9]+$ ]] && prev_up=$up
    api=$(curl -s -m 10 "http://$BOX:8080/api/v2/sync/maindata" 2>/dev/null)
    if [[ "$api" == *dl_info_speed* ]]; then
        # JSON передаём через переменную окружения: stdin у python занят самим скриптом
        IFS=$'\t' read -r dl queue active states < <(API_JSON="$api" python3 - <<'PY' 2>/dev/null
import os, json, collections
d = json.loads(os.environ["API_JSON"]); s = d.get("server_state", {}); ts = d.get("torrents", {})
dl = s.get("dl_info_speed", 0) / 1048576
queue = "%.1f МБ, перегруз=%s" % (s.get("total_queued_size", 0) / 1048576, s.get("write_cache_overload", "?"))
act = [t for t in ts.values() if t.get("state") in ("downloading", "forcedDL")] or [t for t in ts.values() if t.get("state") == "stalledDL"]
a = act[0] if act else None
active = ("%.1f%%, сиды %s/%s, %s" % (a["progress"] * 100, a.get("num_seeds"), a.get("num_complete"), a["state"])) if a else "нет активных"
c = collections.Counter(t.get("state") for t in ts.values())
states = " ".join(f"{k}:{v}" for k, v in sorted(c.items()))
print(f"{dl:.1f}\t{queue}\t{active}\t{states}")
PY
)
        [ -z "$dl" ] && dl="разбор не удался"
    else
        dl="API НЕТ"; queue="-"; active="-"; states=""
    fi
    echo "$now | $p | $up | $dl | $queue | $active | $states | $note" >> "$LOG"
    sleep 60
done
