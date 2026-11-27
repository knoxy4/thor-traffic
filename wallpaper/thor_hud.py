"""Thor HUD feed: localhost-only JSON for the Thor Night wallpaper's status panel.

    python thor_hud.py                          # serve the live machine on 127.0.0.1:47823
    python thor_hud.py --demo                   # serve made-up data (screenshots, trying the wallpaper)
    python thor_hud.py --services OLLAMA=11434,COMFY=8188 --disks C,D --leases gpu,editor,build

GET http://127.0.0.1:<port>/stats?k=<token>. The token lives in hud_token.txt next to this file and is made on first run;
install-wallpaper.ps1 copies it into the wallpaper's cfg.js. Stdlib only, Windows only (it reads system counters through
kernel32 and the GPU through nvidia-smi). One instance per port: a second copy exits when the port is taken.
"""
import argparse
import ctypes
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
NO_WINDOW = 0x08000000

STATE = {"sys": {}, "gpu": {}, "thor": {}, "svc": [], "disk": []}
LOCK = threading.Lock()


def default_dir():
    return os.environ.get("THOR_DIR") or os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "ThorTraffic")


def parse_args():
    p = argparse.ArgumentParser(description="Thor HUD feed for the Thor Night wallpaper")
    p.add_argument("--dir", default=default_dir(), help="Thor state folder (default: $THOR_DIR, else %%ProgramData%%\\ThorTraffic)")
    p.add_argument("--port", type=int, default=47823)
    p.add_argument("--leases", default="gpu,editor,build", help="lease names, in panel order (match your profile)")
    p.add_argument("--services", default="", help="NAME=port pairs probed on 127.0.0.1, e.g. OLLAMA=11434,COMFY=8188")
    p.add_argument("--disks", default="C", help="drive letters whose free space goes in the footer, e.g. C,D")
    p.add_argument("--token-file", default=os.path.join(HERE, "hud_token.txt"))
    p.add_argument("--demo", action="store_true", help="serve made-up data instead of reading the machine")
    return p.parse_args()


def token(path):
    try:
        with open(path, encoding="utf-8") as f:
            t = f.read().strip()
        if t:
            return t
    except OSError:
        pass
    t = secrets.token_hex(16)
    with open(path, "w", encoding="utf-8") as f:
        f.write(t)
    return t


def put(key, val):
    with LOCK:
        STATE[key] = val


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def read_json(p):
    try:
        with open(p, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def loop(fn, every):
    def run():
        while True:
            try:
                fn()
            except Exception as e:  # keep the feed alive; surface the error in the payload
                put("err_" + fn.__name__, str(e))
            time.sleep(every)
    threading.Thread(target=run, daemon=True).start()


# --- live readers ---------------------------------------------------------------------------------------------------

if sys.platform == "win32":
    import ctypes.wintypes as wt

    class FILETIME(ctypes.Structure):
        _fields_ = [("lo", wt.DWORD), ("hi", wt.DWORD)]

    class MEMSTAT(ctypes.Structure):
        _fields_ = [("dwLength", wt.DWORD), ("dwMemoryLoad", wt.DWORD),
                    ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

_prev = [None]


def sys_stats():
    k = ctypes.windll.kernel32
    k.GetTickCount64.restype = ctypes.c_ulonglong
    i, kk, u = FILETIME(), FILETIME(), FILETIME()
    k.GetSystemTimes(ctypes.byref(i), ctypes.byref(kk), ctypes.byref(u))
    cur = tuple((f.hi << 32) | f.lo for f in (i, kk, u))
    cpu = None
    if _prev[0]:
        di, dk, du = (c - p for c, p in zip(cur, _prev[0]))
        total = dk + du  # kernel time includes idle
        cpu = round(100.0 * (total - di) / total, 1) if total else 0.0
    _prev[0] = cur
    m = MEMSTAT()
    m.dwLength = ctypes.sizeof(MEMSTAT)
    k.GlobalMemoryStatusEx(ctypes.byref(m))
    put("sys", {"cpu": cpu,
                "ram_used": round((m.ullTotalPhys - m.ullAvailPhys) / 2**30, 1),
                "ram_total": round(m.ullTotalPhys / 2**30, 1),
                "uptime_s": int(k.GetTickCount64() // 1000)})


def gpu_stream():
    q = "utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw"
    while True:
        try:
            p = subprocess.Popen(["nvidia-smi", "--query-gpu=" + q, "--format=csv,noheader,nounits", "-l", "2"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, creationflags=NO_WINDOW)
            for line in p.stdout:
                v = [x.strip() for x in line.split(",")]
                if len(v) >= 5:
                    put("gpu", {"util": num(v[0]), "vram_used": num(v[1]), "vram_total": num(v[2]),
                                "temp": num(v[3]), "power": num(v[4])})
        except OSError as e:
            put("gpu", {"err": str(e)})
        time.sleep(5)


def parse_iso(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


TICKS_1601 = 504911232000000000  # .NET ticks (from 0001-01-01) at the FILETIME epoch (1601-01-01)


def proc_stamp(pid):
    """The process's start as .NET UTC ticks (thor.ps1's pidStart), or None when it isn't running."""
    if sys.platform != "win32" or not pid:
        return None
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    try:
        code = wt.DWORD()
        if not k.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != 259:  # STILL_ACTIVE
            return None
        c, e, kk, u = FILETIME(), FILETIME(), FILETIME(), FILETIME()
        if not k.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kk), ctypes.byref(u)):
            return ""
        return str(((c.hi << 32) | c.lo) + TICKS_1601)
    finally:
        k.CloseHandle(h)


def same_proc(pid, stamp):
    st = proc_stamp(pid)
    if st is None:
        return False
    return not stamp or not st or st == str(stamp)


def lease_live(L, now):
    """thor.ps1's Lease-State, as far as the panel needs it: live, or not (expired, or its process gone)."""
    if not L or not L.get("by"):
        return False
    until = parse_iso(L.get("until"))
    if until is not None and until <= now:
        # a lease tied to a process keeps going past its expiry while that process runs (with a start stamp to tell it apart)
        return bool(L.get("pid") and L.get("pidStart") and same_proc(L.get("pid"), L.get("pidStart")))
    if L.get("pid") and not same_proc(L.get("pid"), L.get("pidStart")):
        return False
    return True


def entry_live(e, now):
    """A waiter thor.ps1 would still count: not past its drop time, and its process (if it has one) still up."""
    until = parse_iso(e.get("until"))
    if until is not None and until <= now:
        return False
    if e.get("pid") and not same_proc(e.get("pid"), e.get("pidStart")):
        return False
    return True


def make_thor_stats(state_dir, lease_names):
    def thor_stats():
        now = time.time()
        leases = {}
        queued_ids = set()
        for name in lease_names:
            L = read_json(os.path.join(state_dir, "leases", name + ".json")) or {}
            Q = read_json(os.path.join(state_dir, "queue", name + ".json")) or {}
            live = lease_live(L, now)
            entries = [e for e in (Q.get("entries") or []) if isinstance(e, dict) and entry_live(e, now)
                       and not (live and e.get("by") == L.get("by"))]
            queued_ids.update(str(e["job"]) for e in entries if e.get("job"))
            if not live:
                L = {}
            leases[name] = {"by": L.get("by"), "note": L.get("note"), "taken": L.get("taken"),
                            "eta": L.get("eta"), "until": L.get("until"),
                            "queue": [{"by": e.get("by"), "note": e.get("note")} for e in entries]}
        # sessions\ is optional (written by a session tracker, not by thor.ps1); null hides the panel's SESSIONS strip.
        sessions = None
        sd = os.path.join(state_dir, "sessions")
        if os.path.isdir(sd):
            sessions = []
            for e in os.scandir(sd):
                if e.name.endswith(".json") and now - e.stat().st_mtime < 3 * 3600:
                    S = read_json(e.path) or {}
                    sessions.append({"by": S.get("by"), "card": S.get("card"), "seen": S.get("seen")})
            sessions.sort(key=lambda s: s.get("seen") or "", reverse=True)
        jobs = []
        jd = os.path.join(state_dir, "jobs")
        if os.path.isdir(jd):
            for e in os.scandir(jd):
                # a recent file, or a job still in a queue (one held back by -NotBefore can sit there for days)
                if e.name.endswith(".json") and (now - e.stat().st_mtime < 24 * 3600 or e.name[:-5] in queued_ids):
                    J = read_json(e.path) or {}
                    if J.get("state") in ("running", "starting", "queued"):
                        jobs.append({"id": J.get("id"), "lease": J.get("lease"), "note": J.get("note"),
                                     "state": J.get("state"), "started": J.get("started")})
        put("thor", {"order": lease_names, "leases": leases, "sessions": sessions, "jobs": jobs})
    return thor_stats


def make_svc_stats(services, disks):
    def svc_stats():
        out = []
        for name, port in services:
            try:
                socket.create_connection(("127.0.0.1", port), 0.25).close()
                out.append({"name": name, "up": True})
            except OSError:
                out.append({"name": name, "up": False})
        put("svc", out)
        found = []
        for d in disks:
            try:
                u = shutil.disk_usage(d + ":\\")
                found.append({"name": d, "free_gb": round(u.free / 2**30), "total_gb": round(u.total / 2**30)})
            except OSError:
                pass
        put("disk", found)
    return svc_stats


# --- demo -----------------------------------------------------------------------------------------------------------

def demo_state():
    """Made-up numbers in the same shape as the live feed, times relative to now (matches demo\\seed.ps1's story)."""
    def iso(m):
        return (datetime.now(timezone.utc) + timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
    t = time.time()
    wob = (t % 20) / 20.0
    return {
        "sys": {"cpu": round(31 + 9 * wob, 1), "ram_used": 41.6, "ram_total": 63.7, "uptime_s": 3 * 86400 + 5 * 3600 + 17 * 60},
        "gpu": {"util": round(84 + 6 * wob), "vram_used": 9420, "vram_total": 12288, "temp": 71, "power": 287},
        "thor": {
            "order": ["gpu", "editor", "build"],
            "leases": {
                "gpu": {"by": "codex-perf", "note": "fps capture 1440p, 3 cameras", "eta": iso(11), "until": iso(23),
                        "queue": [{"by": "cursor-art.j1", "note": "bake Lumen cards"}, {"by": "claude-audit", "note": "-game smoke test"}]},
                "editor": {"by": "claude-level", "note": "courtyard blockout", "eta": iso(14), "until": iso(94), "queue": []},
                "build": {"by": None, "note": None, "eta": None, "until": None, "queue": []},
            },
            "sessions": [{"by": "claude-level", "card": "level", "seen": iso(-1)},
                         {"by": "codex-perf", "card": "perf", "seen": iso(-2)},
                         {"by": "cursor-art", "card": "art", "seen": iso(-9)},
                         {"by": "claude-audit", "card": "qa", "seen": iso(-74)}],
            "jobs": [{"id": "cursor-art.j1-demo", "lease": "gpu", "note": "bake Lumen cards, tier map", "state": "queued", "started": None}],
        },
        "svc": [{"name": "OLLAMA", "up": True}, {"name": "COMFYUI", "up": False}],
        "disk": [{"name": "C", "free_gb": 412, "total_gb": 1863}, {"name": "D", "free_gb": 88, "total_gb": 1863}],
    }


def demo_loop():
    while True:
        for k, v in demo_state().items():
            put(k, v)
        time.sleep(2)


# --- server ---------------------------------------------------------------------------------------------------------

def make_handler(tok):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path, _, query = self.path.partition("?")
            params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
            if path != "/stats" or not secrets.compare_digest(params.get("k", ""), tok):
                self.send_response(403)
                self.end_headers()
                return
            with LOCK:
                body = json.dumps(dict(STATE, t=time.time())).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")  # the wallpaper is a file:// page
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass
    return Handler


def main():
    a = parse_args()
    tok = token(a.token_file)
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(tok))
    except OSError:
        sys.exit(0)  # already running
    if a.demo:
        threading.Thread(target=demo_loop, daemon=True).start()
    else:
        if sys.platform != "win32":
            sys.exit("thor_hud.py reads Windows counters; use --demo elsewhere")
        lease_names = [x.strip() for x in a.leases.split(",") if x.strip()]
        services = []
        for pair in filter(None, (x.strip() for x in a.services.split(","))):
            name, _, port = pair.partition("=")
            services.append((name.upper(), int(port)))
        disks = [x.strip().rstrip(":\\").upper() for x in a.disks.split(",") if x.strip()]
        loop(sys_stats, 2)
        loop(make_thor_stats(a.dir, lease_names), 3)
        loop(make_svc_stats(services, disks), 10)
        threading.Thread(target=gpu_stream, daemon=True).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
