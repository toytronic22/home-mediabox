#!/system/bin/sh
# Сторож Kodi на проекторе JMGO: журнал ошибок и того, как идёт фильм.
#
# Живёт в /data/local/tmp/kodi-guard.sh и работает от shell: root на проекторе нет.
# Ставит и запускает его команда jmgo с мака. Сон проектора переживает, розетку и
# перезагрузку — нет: после них его заново запускает jmgo.
#
# Журнал — /sdcard/kodi_data/guard/kodi-guard.log, время в нём алматинское
# (часы проектора идут по Китаю). Что пишет:
#  - запуск и закрытие Kodi; если Kodi пропал не штатно — копирует его журнал
#    и выдержку logcat в crash-* рядом;
#  - ошибки и предупреждения Kodi, какой файл открыт и каким декодером;
#  - раз в минуту, пока идёт видео: позиция, буфер, декодер, провалы звука,
#    нагрузка Kodi на процессор, свободная память;
#  - тревоги (строки с «ТРЕВОГА»): фильм стоит при скорости ×1, видео пошло
#    программно (это чёрный экран и рваный звук), провалы звука, пустеет буфер,
#    мало памяти, заставка поверх фильма.
#
# Лечит одно: заставку поверх идущего фильма — будит экран, как кнопка пульта.
# Остальное только записывает: перезапуск Kodi посреди фильма хуже рывка.

D=/sdcard/kodi_data/guard
LOG=$D/kodi-guard.log
KT=/sdcard/kodi_data/.kodi/temp
KLOG=$KT/kodi.log
PIDF=/data/local/tmp/kodi-guard.pid
STEP=15
export TZ='<+05>-5'

old=$(cat $PIDF 2>/dev/null)
if [ -n "$old" ] && [ "$old" != "$$" ] && grep -q kodi-guard /proc/$old/cmdline 2>/dev/null; then
  exit 0
fi
echo $$ > $PIDF
mkdir -p $D

NOISE='Skipped [0-9]+ duplicate messages|missing version attribute|already present with higher version|Could not parse type|has been updated from|Profile 256 not supported'
KEEP=' (error|fatal|warning) <|VideoPlayer::OpenFile|CloseFile|Using codec:|CDVDVideoCodecFFmpeg::Open|Creating audio stream|VideoView creation failed|Application stopped'

say() { echo "$(date '+%F %T') $*" >> $LOG; }

hms() { printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

rpc() {
  printf 'POST /jsonrpc HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#1}" "$1" |
    timeout 5 nc 127.0.0.1 8090 2>/dev/null | tail -n 1
}

secs() {
  echo "$1" | sed -n "s/.*\"$2\":{\"hours\":\([0-9]*\),\"milliseconds\":[0-9]*,\"minutes\":\([0-9]*\),\"seconds\":\([0-9]*\)}.*/\1 \2 \3/p" |
    awk '{print $1 * 3600 + $2 * 60 + $3}'
}

field() { echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }

wake_now() { dumpsys power 2>/dev/null | sed -n 's/^ *mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1; }

ru_wake() {
  case "$1" in
    Awake) echo включён ;;
    Dreaming) echo заставка ;;
    Asleep) echo спит ;;
    Dozing) echo дремлет ;;
    *) echo "${1:-?}" ;;
  esac
}

scan_log() {
  sz=$(stat -c %s $KLOG 2>/dev/null) || return
  [ "$sz" -lt "$off" ] && off=0
  [ "$sz" -eq "$off" ] && return
  tail -c +$((off + 1)) $KLOG 2>/dev/null | head -c $((sz - off)) |
    grep -E "$KEEP" | grep -vE "$NOISE" |
    sed 's/^[0-9-]* [0-9:.]* T:[0-9]* *//; s/<general>: //' | cut -c1-300 | uniq -c |
    awk -v t="$(date '+%F %T')" '{n = $1; sub(/^ *[0-9]+ /, ""); print t " kodi: " $0 (n > 1 ? " (×" n ")" : "")}' |
    head -n 60 >> $LOG
  off=$sz
}

gone_how() {
  if tail -n 300 "$1" 2>/dev/null | grep -qE "Application stopped|Stopping all|Stopping the application"; then
    echo "штатно|"; return
  fi
  lc=$(logcat -d -b main,system,crash -v epoch 2>/dev/null | awk -v t=$((alive - 20)) '$1 >= t')
  fp=$(echo "$lc" | sed -n 's/.*Force stopping org\.xbmc\.kodi .*from pid \([0-9]*\).*/\1/p' | tail -n 1)
  if [ -n "$fp" ]; then
    who=$(ps -A -o PID,NAME | awk -v p=$fp '$1 == p {print $2}')
    echo "вручную|${who:-процесс $fp, уже завершён, скорее всего adb}"; return
  fi
  if echo "$lc" | grep -qiE "lowmemorykiller.*kodi|lmkd.*kodi|Killing [0-9]+:org\.xbmc\.kodi"; then
    echo "система|"; return
  fi
  echo "сбой|"
}

save_crash() {
  f=$D/crash-$(date '+%Y%m%d-%H%M%S')
  cp "$1" $f-kodi.log 2>/dev/null
  logcat -d -b crash 2>/dev/null | tail -n 300 > $f-crash.txt
  logcat -d 2>/dev/null | grep -iE "kodi|xbmc|lowmemorykiller|lmkd|has died" | tail -n 400 > $f-logcat.txt
  say "ТРЕВОГА: $2; журналы — $f-*"
  ls -t $D/crash-* 2>/dev/null | sed 1,30d | while read x; do rm -f "$x"; done
}

summary() {
  lb=$(rpc '{"jsonrpc":"2.0","id":3,"method":"XBMC.GetInfoLabels","params":{"labels":["Player.Process(videodecoder)","VideoPlayer.HdrType","Player.CacheLevel","Player.Process(audiodecoder)","Player.Process(audiochannels)"]}}')
  vdec=$(field "$lb" 'Player.Process(videodecoder)')
  hdr=$(field "$lb" VideoPlayer.HdrType)
  cache=$(field "$lb" Player.CacheLevel)
  adec=$(field "$lb" 'Player.Process(audiodecoder)')
  ach=$(field "$lb" 'Player.Process(audiochannels)' | awk -F, '{print NF}')
  und=$(dumpsys media.audio_flinger 2>/dev/null |
    awk -v p="$kpid" '{for (i = 2; i <= NF - 19; i++) if ($i == p && $(i - 1) == "yes") {print $(i + 19); exit}}')
  cpu=$(awk '{print $14 + $15}' /proc/$kpid/stat 2>/dev/null)
  mem=$(awk '/^MemAvailable/ {printf "%d", $2 / 1024}' /proc/meminfo)
  now=$(date +%s)
  dw=$((now - w_prev))
  dt=$((pos - t_prev))
  load=
  [ -n "$cpu_prev" ] && [ -n "$cpu" ] && [ $dw -gt 0 ] && load="$(((cpu - cpu_prev) / dw))%"
  dund=
  [ -n "$und_prev" ] && [ -n "$und" ] && [ "$und" -ge "$und_prev" ] && dund=$((und - und_prev))
  say "идёт $(hms $pos) из $(hms $tot), буфер ${cache:-?}%, видео ${vdec:-?} ${hdr:-SDR}, звук ${adec:-?} ${ach:-?}к, провалов звука +${dund:-?}, Kodi ${load:-?} ядра, свободно ${mem:-?} МБ"
  case "$vdec" in
    amc-* | '') ;;
    *)
      if [ $sw_warned = 0 ]; then
        say "ТРЕВОГА: видео декодируется программно ($vdec) — чёрный экран или рывки; лечится перезапуском Kodi при включённом экране"
        sw_warned=1
      fi
      ;;
  esac
  if [ $steady = 1 ] && [ "$spd" = 1 ] && [ $dw -ge 45 ] && [ $dw -le 120 ] && [ $dt -lt $((dw * 3 / 4)) ]; then
    say "ТРЕВОГА: фильм стоит — за $dw с прошло $dt с фильма"
  fi
  [ -n "$dund" ] && [ "$dund" -gt 0 ] && say "ТРЕВОГА: провалы звука, +$dund за минуту"
  [ -n "$cache" ] && [ "$cache" -lt 20 ] && say "ТРЕВОГА: буфер почти пуст, ${cache}%"
  [ -n "$mem" ] && [ "$mem" -lt 300 ] && say "ТРЕВОГА: свободно всего $mem МБ памяти"
  t_prev=$pos
  w_prev=$now
  und_prev=$und
  cpu_prev=$cpu
  steady=1
}

kpid_prev=$(pidof org.xbmc.kodi)
alive=$(date +%s)
off=$(stat -c %s $KLOG 2>/dev/null || echo 0)
wake_prev=$(wake_now)
playing=0
spd_prev=
pos=0
cycle=0
say "сторож запущен (pid $$); Kodi: ${kpid_prev:-не запущен}; экран: $(ru_wake $wake_prev)"

while true; do
  cycle=$((cycle + 1))
  if [ $((cycle % 40)) = 0 ] && [ "$(stat -c %s $LOG 2>/dev/null || echo 0)" -gt 2000000 ]; then
    mv -f $LOG $LOG.1
  fi

  kpid=$(pidof org.xbmc.kodi)
  if [ "$kpid" != "$kpid_prev" ]; then
    if [ -n "$kpid_prev" ]; then
      if [ -n "$kpid" ]; then src=$KT/kodi.old.log; else src=$KLOG; fi
      when=
      [ $playing = 1 ] && when=" во время фильма, на $(hms $pos)"
      how=$(gone_how $src)
      who=${how#*|}
      case ${how%%|*} in
        штатно) say "Kodi закрыт штатно$when" ;;
        вручную)
          if [ "$who" = com.jmgo.hippo ] && [ -z "$when" ]; then
            say "Kodi закрыт чистильщиком проектора (com.jmgo.hippo): в фоне он живёт около 30 с"
          elif [ -z "$when" ]; then
            say "Kodi остановлен принудительно ($who)"
          else
            save_crash $src "Kodi остановлен принудительно ($who)$when"
          fi
          ;;
        система) save_crash $src "Kodi выгружен системой$when" ;;
        *) save_crash $src "Kodi упал$when" ;;
      esac
    fi
    if [ -n "$kpid" ]; then
      say "Kodi запущен (pid $kpid)"
      off=0
    fi
    kpid_prev=$kpid
    playing=0
    spd_prev=
  fi

  wake=$(wake_now)
  if [ -n "$wake" ] && [ "$wake" != "$wake_prev" ]; then
    say "экран: $(ru_wake $wake_prev) → $(ru_wake $wake)"
    wake_prev=$wake
  fi

  if [ -n "$kpid" ]; then
    alive=$(date +%s)
    scan_log
    act=$(rpc '{"jsonrpc":"2.0","id":1,"method":"Player.GetActivePlayers"}')
    case "$act" in
      *'"type":"video"'*)
        pl=$(echo "$act" | sed -n 's/.*"playerid":\([0-9]*\).*/\1/p' | head -n 1)
        pr=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"Player.GetProperties\",\"params\":{\"playerid\":${pl:-1},\"properties\":[\"time\",\"totaltime\",\"speed\"]}}")
        p=$(secs "$pr" time)
        [ -n "$p" ] && pos=$p
        tot=$(secs "$pr" totaltime)
        spd=$(echo "$pr" | sed -n 's/.*"speed":\(-\{0,1\}[0-9]*\).*/\1/p')
        if [ $playing = 0 ]; then
          playing=1
          tick=0
          sw_warned=0
          steady=0
          t_prev=$pos
          w_prev=$(date +%s)
          und_prev=
          cpu_prev=
          title=$(field "$(rpc '{"jsonrpc":"2.0","id":4,"method":"XBMC.GetInfoLabels","params":{"labels":["VideoPlayer.Title"]}}')" VideoPlayer.Title)
          say "начал видео «${title:-?}» с $(hms $pos) из $(hms ${tot:-0})"
        elif [ -n "$spd" ] && [ -n "$spd_prev" ] && [ "$spd" != "$spd_prev" ]; then
          case "$spd" in
            0) say "пауза на $(hms $pos)" ;;
            1) say "продолжил с $(hms $pos)" ;;
            *) say "перемотка ×$spd с $(hms $pos)" ;;
          esac
          steady=0
          t_prev=$pos
          w_prev=$(date +%s)
        fi
        [ -n "$spd" ] && spd_prev=$spd
        if [ "$wake" = Dreaming ] && [ "$spd" = 1 ]; then
          input keyevent KEYCODE_WAKEUP
          say "ТРЕВОГА: заставка поверх идущего фильма — разбудил экран"
        fi
        tick=$((tick + 1))
        [ $((tick % 4)) = 0 ] && summary
        ;;
      *)
        if [ $playing = 1 ]; then
          say "видео остановлено на $(hms $pos)"
          playing=0
          spd_prev=
        fi
        ;;
    esac
  fi

  sleep $STEP
done
