#!/bin/bash
# Утренняя сводка по ночным логам: night.log с приставки + night-<дата>.log с мака.
# Запуск: ~/ugoos-tools/night-report.sh [дата]   (по умолчанию — сегодня)
D=${1:-$(date +%F)}
DEV=/tmp/night-device-$D.log
adb shell cat /data/local/tmp/aria2/night.log > "$DEV" 2>/dev/null
python3 - "$DEV" "$HOME/ugoos-tools/night-$D.log" <<'PY'
import sys, re, statistics as st, collections
from datetime import datetime
dev, mac = sys.argv[1], sys.argv[2]
def ts(s): return datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S")
def fnum(s):
    m = re.match(r"\s*([\d.]+)", s); return float(m[1]) if m else None

print("=== Приставка (night.log) ===")
rows=[]; events=[]
try:
    for line in open(dev, encoding="utf-8", errors="replace"):
        if " !! " in line: events.append(line.strip()); continue
        if line.startswith("#") or " | " not in line:
            if "наблюдение" in line: print("  ", line.strip())
            continue
        f=[x.strip() for x in line.split("|")]
        if len(f) < 11: continue
        try: t=ts(f[0]); up=int(f[1])
        except ValueError: continue
        m=re.match(r"([\d.]+), (\d+) мс, ([\d.]+), (\d+)%, (\d+)", f[2])
        disk = dict(w=float(m[1]), lat=int(m[2]), r=float(m[3]), busy=int(m[4])) if m else None
        rows.append(dict(t=t, up=up, disk=disk, diskraw=f[2], dirty=f[3], load=float(f[4] or 0), mem=f[5], temp=f[6],
                         dl=fnum(f[7]), queue=f[8], active=f[9], diag=f[10]))
except FileNotFoundError:
    print("  лога с приставки нет")
if rows:
    print(f"  записей: {len(rows)}, с {rows[0]['t']:%H:%M} по {rows[-1]['t']:%H:%M}")
    reboots=[r for a,r in zip(rows,rows[1:]) if r['up']<a['up']]
    print(f"  перезагрузок: {len(reboots)}" + "".join(f" — в {r['t']:%H:%M}" for r in reboots))
    gaps=[(a['t'],b['t']) for a,b in zip(rows,rows[1:]) if (b['t']-a['t']).total_seconds()>180]
    print(f"  провалов в логе (>3 мин без записи — висла или лежала): {len(gaps)}" + "".join(f" — {a:%H:%M}→{b:%H:%M}" for a,b in gaps))
    dls=[r['dl'] for r in rows if r['dl'] is not None]
    if dls:
        print(f"  скорость сети: средняя {st.mean(dls):.1f} МБ/с, макс {max(dls):.1f}, минут ниже 1 МБ/с: {sum(1 for x in dls if x<1)} из {len(dls)}")
        print(f"  скачано за ночь примерно {sum(dls)*60/1024:.0f} ГБ")
    noapi=[r for r in rows if r['dl'] is None]
    if noapi: print(f"  качалка не отвечала: {len(noapi)} мин" + "".join(f" — {r['t']:%H:%M}" for r in noapi[:8]))
    diags=collections.Counter(r['diag'] for r in rows)
    print("  диагнозы по минутам: " + ", ".join(f"{k} — {v}" for k,v in diags.most_common()))
    ds=[r['disk'] for r in rows if r['disk']]
    if ds:
        lats=[d['lat'] for d in ds if d['w']>0.5]
        print(f"  диск: запись средняя {st.mean(d['w'] for d in ds):.1f} МБ/с, макс {max(d['w'] for d in ds):.1f}; латентность записи под нагрузкой: медиана {st.median(lats) if lats else 0:.0f} мс, макс {max(lats) if lats else 0} мс, минут >300 мс: {sum(1 for x in lats if x>300)}")
    lost=[r for r in rows if "ПРОПАЛ" in r['diskraw'] or "НЕ СМОНТИРОВАНА" in r['diskraw']]
    if lost: print(f"  !!! диск пропадал: {len(lost)} мин" + "".join(f" — {r['t']:%H:%M}" for r in lost[:8]))
    temps=[int(r['temp']) for r in rows if r['temp'].isdigit()]; dirt=[int(r['dirty']) for r in rows if r['dirty'].isdigit()]
    print(f"  загрузка макс {max(r['load'] for r in rows):.1f}, температура макс {max(temps) if temps else '?'} °C, грязных страниц макс {max(dirt) if dirt else '?'} МБ")
    print(f"  в начале: {rows[0]['active']}\n  в конце:  {rows[-1]['active']}")
    if events:
        print(f"  события ({len(events)}):")
        for e in events[:40]: print("   ", e[11:])
        if len(events)>40: print(f"    … и ещё {len(events)-40}")

print(f"\n=== Снаружи, с мака ({mac.split('/')[-1]}) ===")
try:
    lines=[l for l in open(mac, encoding="utf-8", errors="replace") if " | " in l and not l.startswith("#")]
    print(f"  записей: {len(lines)}")
    bad=False
    for k,lab in [("НЕТ ПИНГА","нет пинга"),("adb НЕТ","adb не отвечал"),("API НЕТ","качалка не отвечала"),("ПЕРЕЗАГРУЗКА","перезагрузка")]:
        hit=[l.split(" | ")[0] for l in lines if k in l]
        if hit: bad=True; print(f"  {lab}: {len(hit)} мин" + "".join(f" — {h[11:16]}" for h in hit[:8]))
    over=[l.split(" | ")[0] for l in lines if (m:=re.search(r"перегруз=([\d.]+)", l)) and float(m[1])>=50]
    if over: bad=True; print(f"  качалка жаловалась на перегруз диска (≥50 %): {len(over)} мин" + "".join(f" — {h[11:16]}" for h in over[:8]))
    if not bad: print("  снаружи всё ровно: пинг, adb и качалка отвечали всю ночь, перегруза диска не было")
except FileNotFoundError:
    print("  лога с мака нет (мак спал?)")
PY
