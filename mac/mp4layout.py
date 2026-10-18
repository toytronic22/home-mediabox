import struct, sys, urllib.request

HEAD = 16 * 2**20


def load(src):
    if src.startswith("http"):
        r = urllib.request.Request(src, headers={"Range": "bytes=0-%d" % (HEAD - 1)})
        return urllib.request.urlopen(r, timeout=120).read()
    with open(src, "rb") as f:
        return f.read(HEAD)


def boxes(b, s, e):
    while s + 8 <= e:
        sz, t = struct.unpack(">I4s", b[s:s + 8])
        h = 8
        if sz == 1:
            sz = struct.unpack(">Q", b[s + 8:s + 16])[0]
            h = 16
        if sz == 0:
            sz = e - s
        yield t.decode("latin1"), s + h, min(s + sz, e)
        s += sz


def find(b, s, e, path):
    for t, cs, ce in boxes(b, s, e):
        if t == path[0]:
            if len(path) == 1:
                yield cs, ce
            else:
                yield from find(b, cs, ce, path[1:])


def table(d, ts, te, name, fmt):
    a, _ = next(find(d, ts, te, ["mdia", "minf", "stbl", name]))
    n = struct.unpack(">I", d[a + 4:a + 8])[0]
    w = struct.calcsize(fmt)
    return [struct.unpack(fmt, d[a + 8 + w * i:a + 8 + w * (i + 1)]) for i in range(n)]


def track(d, ts, te):
    m, _ = next(find(d, ts, te, ["mdia", "mdhd"]))
    scale = struct.unpack(">I", d[m + 12:m + 16] if d[m] == 0 else d[m + 20:m + 24])[0]
    h, _ = next(find(d, ts, te, ["mdia", "hdlr"]))
    kind = d[h + 8:h + 12].decode("latin1")
    stts = table(d, ts, te, "stts", ">II")
    stsc = table(d, ts, te, "stsc", ">III")
    if list(find(d, ts, te, ["mdia", "minf", "stbl", "stco"])):
        offs = [x[0] for x in table(d, ts, te, "stco", ">I")]
    else:
        offs = [x[0] for x in table(d, ts, te, "co64", ">Q")]
    times, t = [], 0
    for cnt, dl in stts:
        for _ in range(cnt):
            times.append(t / scale)
            t += dl
    chunks, si = [], 0
    for ci, off in enumerate(offs):
        if si >= len(times):
            break
        chunks.append((times[si], off / 2**20))
        si += [x for x in stsc if x[0] <= ci + 1][-1][1]
    return kind, chunks


def at(chunks, sec):
    best = None
    for t, mb in chunks:
        if t <= sec:
            best = mb
    return best


d = load(sys.argv[1])
moov = list(find(d, 0, len(d), ["moov"]))
if not moov:
    sys.exit("moov нет в первых %d МБ — файл без faststart, разбор не выйдет" % (HEAD // 2**20))
tracks = [track(d, ts, te) for ts, te in find(d, moov[0][0], moov[0][1], ["trak"])]
video = next(c for k, c in tracks if k == "vide")
end = int(video[-1][0])
marks = list(range(600, end, 600))
print("минута: " + " ".join("%6d" % (s // 60) for s in marks))
worst = 0
for i, (kind, chunks) in enumerate(tracks):
    row = []
    for s in marks:
        mb = at(chunks, s)
        if mb is None:
            row.append("     -")
            continue
        gap = at(video, s) - mb
        worst = max(worst, gap)
        row.append("%6d" % gap)
    print("%d %s отставание от видео, МБ: %s" % (i, kind, " ".join(row)))
cache = float(sys.argv[2]) if len(sys.argv) > 2 else 12
print("наибольшее отставание %d МБ, кэш TorrServer %g ГБ — %s" % (worst, cache, "больше кэша: плеер полезет назад за выброшенными кусками" if worst > cache * 1024 else "влезает"))
