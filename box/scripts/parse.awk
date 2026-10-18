# Вход: одна строка = сырое имя раздачи (имя папки или файла из Download).
# Выход: строки KEY=VALUE. Только POSIX awk, никаких gawk-измов.
BEGIN{
  TECH="^(10bit|480p|576p|720p|1080p|1080i|2160p|4k|uhd|hdr|hdr10|hdr10\\+|dv|hdr-dv|dolby|dolbyvision|bdremux|bdrip|bluray|blu-ray|brrip|webrip|web-dl|web-dlrip|webdl|hdrip|hdtv|dvdrip|dvdscr|remux|hybrid|x264|x265|h264|h265|hevc|avc|ac3|dts|dts-hd|aac|atmos|truehd|flac|repack|proper|extended|unrated|remastered|ts|rip|by)$"
  SEASONW="^(сезон|сезоны|season|seasons|серии|серия|episodes|эпизоды)"
}
function trim(s){ sub(/^[ ._-]+/,"",s); sub(/[ ._-]+$/,"",s); return s }
# двоеточие запрещено на exFAT -> " - "
function fsclean(s){ gsub(/ *: */," - ",s)
  gsub(/\*/," ",s); gsub(/\?/," ",s); gsub(/"/," ",s); gsub(/</," ",s)
  gsub(/>/," ",s); gsub(/\|/," ",s); gsub(/\\/," ",s); gsub("/"," ",s)
  gsub(/  +/," ",s); sub(/^[ .]+/,"",s); sub(/[ .]+$/,"",s); return s }
function has_digit(s){ return (s ~ /[0-9]/) }
function seasonnum(s,  t){ t=s; if(match(t,/[0-9]+/)) return substr(t,RSTART,RLENGTH)+0; return 0 }

{
  raw=$0
  TYPE="movie"; RU=""; EN=""; YEAR=""; SEASON=""; MULTI=0; SRC="plain"

  # 0. срезать расширение видео (регистронезависимо, без флага I)
  low=tolower(raw)
  if (low ~ /\.(mkv|mp4|avi|m4v|ts|mov|m2ts|iso)$/) { raw=substr(raw,1,length(raw)-length(low)+length(low)); sub(/\.[^.]+$/,"",raw) }

  # 0а. тег релиз-группы в начале: «[GoldenBridge] Hopper et le Hamster des Ténèbres (2022) [BDRemux]».
  # С ним заголовок срезался по первой «[» целиком, и 20.09.2026 в базу фильмов ушло всё имя.
  while (raw ~ /^\[[^]]*\]/) sub(/^\[[^]]*\][ ._-]*/,"",raw)

  # ---------- формат RICH: "Рус / Eng / Сезон: 2 (Режиссёр) [2024, ...]" ----------
  if (raw ~ / \/ / || raw ~ / \[/) {
    SRC="rich"
    # год = первые 4 цифры после первой "["
    tmp=raw
    if (match(tmp,/\[[^]0-9]*(19|20)[0-9][0-9]/)) {
      seg=substr(tmp,RSTART,RLENGTH); if (match(seg,/(19|20)[0-9][0-9]/)) YEAR=substr(seg,RSTART,RLENGTH)
    }
    # у зарубежных релизов год в скобках: «Title (2022) [BDRemux] [1080p]»
    if (YEAR=="" && match(tmp,/\((19|20)[0-9][0-9]\)/)) YEAR=substr(tmp,RSTART+1,4)
    # заголовочная часть: до " (" режиссёра и до " ["
    head=raw; sub(/ *\(.*$/,"",head); sub(/ *\[.*$/,"",head)
    # сезон ищем во ВСЕЙ строке (он мог остаться в отрезанном хвосте)
    if (match(raw,/[Сс]езон[ыа]*:? *[0-9]+/) || match(raw,/[Ss]eason:? *[0-9]+/)) {
      TYPE="show"; SEASON=seasonnum(substr(raw,RSTART,RLENGTH))
      if (substr(raw,RSTART,RLENGTH+3) ~ /[0-9]+ *[-–] *[0-9]/) MULTI=1
    }
    # варианты названия
    n=split(head,P,/ \/ /); k=0
    for(i=1;i<=n;i++){ p=trim(P[i]); if(p=="") continue
      lp=tolower(p); if (lp ~ SEASONW) continue
      k++; if(k==1) RU=p; else if(k==2 && EN=="") EN=p }
    if (RU=="" ) RU=trim(head)
  }
  # ---------- формат BRACKET: "Укрытие (Silo) Сезон 3" / "Silo (Season 2) ..." ----------
  else if (match(raw,/ \([^)]+\)/)) {
    SRC="bracket"
    inner=substr(raw,RSTART+2,RLENGTH-3)
    before=trim(substr(raw,1,RSTART-1))
    after=substr(raw,RSTART+RLENGTH)
    li=tolower(inner)
    if (inner ~ /^(19|20)[0-9][0-9]$/) { YEAR=inner; RU=before }
    else if (li ~ /season|сезон/) { TYPE="show"; SEASON=seasonnum(inner); RU=before }
    else if (!has_digit(inner)) { RU=before; EN=inner }        # альт-название
    else { RU=before }
    # сезон/год могли остаться в хвосте
    if (SEASON=="" && (match(after,/[Сс]езон[ыа]*:? *[0-9]+/) || match(after,/[Ss]eason:? *[0-9]+/))) {
      TYPE="show"; SEASON=seasonnum(substr(after,RSTART,RLENGTH)) }
    if (YEAR=="" && match(after,/(19|20)[0-9][0-9]/)) YEAR=substr(after,RSTART,RLENGTH)
  }
  # ---------- формат PLAIN: "The.Sheep.Detectives.2026.x265..." ----------
  else {
    norm=raw; gsub(/[._]+/," ",norm); gsub(/  +/," ",norm); norm=trim(norm)
    n=split(norm,T," ")
    techpos=0; yidx=0; spos=0
    for(i=1;i<=n;i++){
      t=tolower(T[i])
      if (spos==0 && (t ~ /^s[0-9][0-9]?$/ || t ~ /^s[0-9][0-9]?e[0-9]/ || t ~ /^season$/ || t=="сезон")) { spos=i }
      if (t ~ /^(19|20)[0-9][0-9]$/ && (techpos==0)) yidx=i
      if (techpos==0 && t ~ TECH) techpos=i
    }
    cut = n+1
    if (techpos>0 && techpos<cut) cut=techpos
    if (spos>0   && spos<cut)     cut=spos
    if (yidx>0   && yidx<cut)     { YEAR=T[yidx]; cut=yidx }
    title=""
    for(i=1;i<cut;i++) title = title (title==""?"":" ") T[i]
    RU=trim(title)
    if (spos>0) { TYPE="show"
      st=tolower(T[spos])
      if (st ~ /^s[0-9]/) SEASON=seasonnum(st)
      else if (spos<n)    SEASON=seasonnum(T[spos+1])
    }
  }

  # название не вычиталось — имя без тегов в скобках, а не сырое имя с расширением («….mkv.mkv»)
  if (trim(RU)=="") { RU=raw; gsub(/\[[^]]*\]/," ",RU); gsub(/  +/," ",RU); RU=trim(RU) }

  # Диапазон сезонов прямо в названии («Sherlock S1-3», «Silo S01-S03»). Ни одна ветка
  # выше его не понимает: слова «сезон»/«season» нет, а токен «S1-3» не подходит под
  # «^s[0-9]$». Из-за этого 18.09.2026 «Sherlock S1-3 BDRip 1080p [Lizard]» уехал в
  # «Разобрать» как сборник фильмов, да ещё и с техническим хвостом вместо названия.
  m=split(RU,W," "); cutw=0
  for(i=1;i<=m;i++){ lw=tolower(W[i])
    if (lw ~ /^s[0-9][0-9]?(-s?[0-9][0-9]?)?$/) { cutw=i; break } }
  if (cutw>0) {
    TYPE="show"
    if (SEASON=="" || SEASON==0) SEASON=seasonnum(W[cutw])
    if (W[cutw] ~ /-/) MULTI=1
    t2=""; for(i=1;i<cutw;i++) t2 = t2 (t2==""?"":" ") W[i]
    if (trim(t2)!="") RU=trim(t2)
  }

  # эпизодный маркер где угодно -> точно сериал
  if (raw ~ /[Ss][0-9][0-9]?[ ._x-]*[Ee][0-9]/) TYPE="show"
  if (TYPE=="show" && (SEASON==""||SEASON==0)) SEASON=1
  if (TYPE=="show") SEASON=sprintf("%02d",SEASON)

  printf "SRC=%s\nTYPE=%s\nTITLE_RU=%s\nTITLE_EN=%s\nYEAR=%s\nSEASON=%s\nMULTI=%d\n",
         SRC, TYPE, fsclean(RU), fsclean(EN), YEAR, SEASON, MULTI
}
