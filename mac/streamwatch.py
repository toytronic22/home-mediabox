import json, subprocess, sys, time, urllib.request, datetime
K="http://192.168.1.10:8090/jsonrpc"; T="http://192.168.1.10:8091"; H=sys.argv[1]
DUR=int(sys.argv[2]) if len(sys.argv)>2 else 2400
LOG=sys.argv[3] if len(sys.argv)>3 else "streamwatch.log"
def post(url, body, t=5):
    r=urllib.request.Request(url,data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=t).read())
def adb(cmd):
    try: return subprocess.run(["adb","-s","192.168.1.10:5555","shell",cmd],capture_output=True,text=True,timeout=10).stdout.strip()
    except Exception as e: return "ERR"
REMOTE=("grep -c 'stream stalled' /sdcard/Android/data/org.xbmc.kodi/files/.kodi/temp/kodi.log; "
        "grep -c 'timeout waiting for buffer' /sdcard/Android/data/org.xbmc.kodi/files/.kodi/temp/kodi.log; "
        "grep 'frame count' /sys/class/vdec/vdec_status | tr -dc 0-9; echo; "
        "grep MemAvailable /proc/meminfo | tr -dc 0-9; echo; pidof TorrServer; cat /sys/class/display/mode")
prev=None; start=time.time()
with open(LOG,"a") as f:
    f.write("time kodi_pos speed ahead_s | frames dframes | stalls bufwait | ts_MBps peers | memavail_MB ts_pid mode | flags\n")
    while time.time()-start < DUR:
        now=datetime.datetime.now().strftime("%H:%M:%S"); flags=[]
        try:
            r=post(K,{"jsonrpc":"2.0","id":1,"method":"Player.GetProperties","params":{"playerid":1,"properties":["time","totaltime","speed","percentage","cachepercentage"]}}).get("result")
        except Exception as e: r=None; flags.append("KODI_RPC_FAIL")
        if r:
            t=r["time"]; pos=t["hours"]*3600+t["minutes"]*60+t["seconds"]; spd=r["speed"]; tt=r["totaltime"]; ahead=(r["cachepercentage"]-r["percentage"])/100*(tt["hours"]*3600+tt["minutes"]*60+tt["seconds"])
        else: pos=spd=ahead=None; flags.append("NO_PLAYER")
        try:
            s=post(T+"/torrents",{"action":"get","hash":H}); tsv="%.1f %s/%s"%(s.get("download_speed",0)/1e6,s.get("active_peers"),s.get("total_peers"))
        except Exception: tsv="- -"; flags.append("TS_FAIL")
        lines=adb(REMOTE).splitlines()+[""]*7
        stalls,bufw,frames,mem,tspid,mode=lines[0],lines[1],lines[2],lines[3],lines[4],lines[5]
        if not tspid: flags.append("TS_DEAD")
        df=""
        if prev:
            if pos is not None and prev[0] is not None and spd==1 and pos-prev[0]<8: flags.append("POS_STUCK")
            try:
                df=int(frames)-int(prev[1])
                if spd==1 and df<=0: flags.append("FRAMES_STUCK")
            except Exception: pass
            try:
                if int(stalls)>int(prev[2]): flags.append("STALL+%d"%(int(stalls)-int(prev[2])))
                if int(bufw)>int(prev[3]): flags.append("BUFWAIT+%d"%(int(bufw)-int(prev[3])))
            except Exception: pass
        posS="%d:%02d"%(pos//60,pos%60) if pos is not None else "-"
        aheadS="%.0f"%ahead if ahead is not None else "-"
        memS=str(int(mem)//1024) if mem.isdigit() else mem
        f.write(f"{now} {posS} {spd} {aheadS} | {frames} {df} | {stalls} {bufw} | {tsv} | {memS} {tspid} {mode} | {' '.join(flags)}\n"); f.flush()
        prev=(pos,frames,stalls,bufw)
        time.sleep(15)
    f.write("END\n")
