# Достаёт id и оригинальное название из ПЕРВОГО результата поиска TMDB.
# Вход — сырой JSON одной или несколькими строками. Выход: TMDB_ID=.. / TMDB_TITLE=..
# match() в awk находит первое вхождение, поэтому берём именно первый результат.
{ all = all $0 }
END{
  # отрезаем всё до начала массива результатов
  i = index(all, "\"results\":[")
  if (i == 0) exit 0
  rest = substr(all, i + 11)
  # первый объект результата — до "},{"
  j = index(rest, "},{")
  if (j > 0) rest = substr(rest, 1, j)

  if (match(rest, /"id":[0-9]+/))
    id = substr(rest, RSTART + 5, RLENGTH - 5)

  if (match(rest, /"original_title":"[^"]*"/))
    t = substr(rest, RSTART + 18, RLENGTH - 19)
  else if (match(rest, /"original_name":"[^"]*"/))
    t = substr(rest, RSTART + 17, RLENGTH - 18)

  if (match(rest, /"release_date":"[0-9][0-9][0-9][0-9]/))
    y = substr(rest, RSTART + 16, 4)
  else if (match(rest, /"first_air_date":"[0-9][0-9][0-9][0-9]/))
    y = substr(rest, RSTART + 18, 4)

  gsub(/\\\//, "/", t)
  printf "TMDB_ID=%s\nTMDB_TITLE=%s\nTMDB_YEAR=%s\n", id, t, y
}
