#!/usr/bin/env python3
"""Run the HAPanel UI locally with simulated data (no HAProxy needed).

    python3 tools/demo_server.py [port]      then open http://localhost:8080/hapanel/

Everything shown is made up: documentation IP ranges, example.com domains, fake processes.
Any password works on the demo login page.
"""
import json
import math
import os
import random
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PANEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "panel")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
NAME = "edge-01"
START = time.time()
STATIC = {"/hapanel/manifest.webmanifest": "application/manifest+json", "/hapanel/sw.js": "text/javascript",
          "/hapanel/icon-192.png": "image/png", "/hapanel/icon-512.png": "image/png",
          "/hapanel/apple-touch-icon.png": "image/png"}
SITES = [("example.com", "be_web", 180, 2), ("api.example.com", "be_api", 95, 3), ("static.example.com", "be_static", 60, 1)]


def wave(t, period, lo, hi, phase=0.0):
    return lo + (hi - lo) * (0.5 + 0.5 * math.sin(2 * math.pi * (t / period) + phase))


def rate_at(t):
    """Requests/s across all sites at time t (two overlapping waves)."""
    return 190 + 70 * math.sin(2 * math.pi * t / 420) + 20 * math.sin(2 * math.pi * t / 97 + 1.3)


def requests_until(t):
    """Integral of rate_at, so the request counters match the rate curve exactly."""
    return (190 * t - 70 * 420 / (2 * math.pi) * math.cos(2 * math.pi * t / 420)
            - 20 * 97 / (2 * math.pi) * math.cos(2 * math.pi * t / 97 + 1.3))


def iso(dt):
    return dt.astimezone(timezone.utc).isoformat()


def snapshot():
    now = time.time()
    up = now - START + 12 * 86400 + 4 * 3600
    total_rate = max(0, rate_at(now))
    req_tot = int(48_000_000 + requests_until(now) - requests_until(START))
    rows = []
    for fe, share in (("http", 0.03), ("https", 0.97)):
        rows.append({"pxname": fe, "svname": "FRONTEND", "status": "OPEN", "req_rate": round(total_rate * share),
                     "req_tot": int(req_tot * share), "scur": int(wave(now, 300, 900, 1500) * share),
                     "smax": 4120, "dreq": 37 if fe == "https" else 0, "ereq": 12,
                     "bin": int(req_tot * share * 610), "bout": int(req_tot * share * 14800)})
    for host, be, rtime, nsrv in SITES:
        share = {"be_web": .55, "be_api": .33, "be_static": .12}[be]
        tot = int(req_tot * share)
        rows.append({"pxname": be, "svname": "BACKEND", "status": "UP", "rate": round(total_rate * share),
                     "scur": int(wave(now, 200, 40, 120) * share * 4), "stot": tot,
                     "hrsp_1xx": 0, "hrsp_2xx": int(tot * .962), "hrsp_3xx": int(tot * .021),
                     "hrsp_4xx": int(tot * .0165), "hrsp_5xx": int(tot * .0005),
                     "rtime": int(rtime + random.uniform(-8, 8)), "bin": tot * 610, "bout": tot * 14800,
                     "lastchg": int(up)})
        for i in range(nsrv):
            rows.append({"pxname": be, "svname": f"{be[3:]}{i + 1}", "status": "UP", "check_status": "L7OK",
                         "check_duration": random.randint(1, 4), "scur": random.randint(5, 40),
                         "stot": tot // nsrv, "hrsp_2xx": int(tot * .962) // nsrv, "hrsp_4xx": int(tot * .0165) // nsrv,
                         "hrsp_5xx": int(tot * .0005) // nsrv, "rtime": int(rtime + random.uniform(-15, 15)),
                         "bin": tot * 610 // nsrv, "bout": tot * 14800 // nsrv, "lastchg": int(up)})
    info = {"Version": "3.2.4-1", "Uptime": "12d 4h%02dm%02ds" % ((now // 60) % 60, now % 60),
            "CurrConns": int(wave(now, 300, 900, 1500)), "Maxconn": 100000, "CumReq": req_tot,
            "CumConns": int(req_tot * .31), "ConnRate": int(total_rate * .3), "MaxConnRate": 812,
            "SslRate": int(total_rate * .08), "MaxSslRate": 240, "CurrSslConns": int(wave(now, 300, 850, 1400)),
            "SslFrontendSessionReuse_pct": 71, "Nbthread": 4, "Idle_pct": int(wave(now, 120, 88, 96))}
    cores = [round(wave(now, 60 + 13 * i, 6, 38, i), 1) for i in range(4)]
    cpu = sum(cores) / 4
    local = datetime.now().astimezone()
    sys_ = {
        "hostname": NAME, "os": "Debian GNU/Linux 13 (trixie)", "kernel": "6.12.0-amd64", "cores": 4,
        "time": iso(local), "uptime": up, "load": [round(cpu / 25, 2), round(cpu / 27, 2), round(cpu / 30, 2)],
        "cpu": round(cpu, 1), "cpu_cores": cores,
        "cpu_detail": {"busy": round(cpu, 1), "user": round(cpu * .68, 1), "system": round(cpu * .27, 1),
                       "iowait": round(cpu * .04, 1), "steal": round(cpu * .01, 1)},
        "mem": {"total": 8 * 2**30, "used": int(wave(now, 900, 2.6, 2.9) * 2**30), "buffers": 180 * 2**20,
                "cached": int(2.4 * 2**30), "swap_total": 2 * 2**30, "swap_used": 24 * 2**20},
        "disk": {"total": 160 * 10**9, "used": 41 * 10**9},
        "net": {"rx_rate": total_rate * 900, "tx_rate": total_rate * 16000,
                "rx_total": int(req_tot * 640), "tx_total": int(req_tot * 15200)},
        "tasks": {"total": 162, "user": 41, "kernel": 121, "threads": 233, "running": 2},
        "haproxy_rss": 182 * 2**20,
        "ips": [{"iface": "eth0", "family": "IPv4", "addr": "203.0.113.10"},
                {"iface": "eth0", "family": "IPv6", "addr": "2001:db8:10::10"}],
        "sites": [{"host": h, "backend": b} for h, b, _, _ in SITES],
        "certs": [{"file": f"{h}.pem", "names": [h], "issuer": "Let's Encrypt",
                   "expires": iso(local + timedelta(days=d)), "days_left": d}
                  for h, d in (("example.com", 74), ("api.example.com", 61), ("static.example.com", 88),
                               ("panel.example.com", 52))],
        "procs": procs(now),
        "cron": cron(local),
    }
    return {"rows": rows, "info": info, "settings": {"name": NAME, "sessions": 2}, "sys": sys_, "ts": now * 1000}


def procs(now):
    base = [("haproxy", 4, "/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid", 182, 9.0),
            ("app", 12, "node /srv/app/server.js", 412, 6.5), ("app", 12, "node /srv/app/worker.js", 298, 2.2),
            ("postgres", 1, "postgres: 17/main: checkpointer", 96, 0.4),
            ("postgres", 1, "/usr/lib/postgresql/17/bin/postgres -D /var/lib/postgresql/17/main", 210, 1.1),
            ("redis", 5, "/usr/bin/redis-server 127.0.0.1:6379", 38, 0.6),
            ("root", 1, "/usr/bin/python3 -I /usr/local/sbin/hapanel-collector", 14, 1.4),
            ("root", 1, "/usr/lib/systemd/systemd-journald", 22, 0.3), ("root", 1, "/usr/sbin/cron -f", 3, 0.0),
            ("root", 1, "sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups", 9, 0.0),
            ("root", 3, "/usr/bin/python3 /usr/bin/fail2ban-server -xf start", 31, 0.1),
            ("root", 1, "/sbin/init", 12, 0.0), ("systemd-timesync", 2, "/usr/lib/systemd/systemd-timesyncd", 7, 0.0)]
    out = []
    for i, (user, thr, cmd, rss_mb, cpu) in enumerate(base):
        c = max(0.0, cpu * wave(now, 30 + i * 7, .6, 1.4, i))
        out.append({"pid": 400 + i * 137, "user": user, "state": "R" if c > 5 else "S", "nice": 0, "threads": thr,
                    "cpu": round(c, 1), "mem": round(rss_mb / 8192 * 100, 1), "rss": rss_mb * 2**20,
                    "time": round(3600 * (cpu + .2) * 7.3 + i * 11, 1), "cmd": cmd})
    return sorted(out, key=lambda p: -p["cpu"])


def cron(local):
    def at(h, m, days=0):
        d = (local + timedelta(days=days)).replace(hour=h, minute=m, second=0, microsecond=0)
        return d if d > local else d + timedelta(days=1)
    nxt_hour = (local + timedelta(hours=1)).replace(minute=17, second=0, microsecond=0)
    jobs = [
        {"source": "crontab:root", "user": "root", "schedule": "4 4,10,16,22 * * *",
         "human": "Daily at 04:04, 10:04, 16:04, 22:04", "command": "/opt/acme.sh/acme.sh --cron --home /opt/acme.sh > /dev/null",
         "next": iso(at(16, 4)), "last": iso(local - timedelta(hours=3, minutes=12))},
        {"source": "crontab:deploy", "user": "deploy", "schedule": "30 2 * * *", "human": "Daily at 02:30",
         "command": "/srv/app/bin/backup-db --keep 14", "next": iso(at(2, 30)), "last": iso(local - timedelta(hours=9))},
        {"source": "/etc/crontab", "user": "root", "schedule": "17 * * * *", "human": "Hourly at :17",
         "command": "cd / && run-parts --report /etc/cron.hourly", "next": iso(nxt_hour),
         "last": iso(nxt_hour - timedelta(hours=1))},
        {"source": "/etc/crontab", "user": "root", "schedule": "25 6 * * *", "human": "Daily at 06:25",
         "command": "test -x /usr/sbin/anacron || { cd / && run-parts --report /etc/cron.daily; }", "next": iso(at(6, 25)), "last": None},
        {"source": "/etc/cron.d/e2scrub_all", "user": "root", "schedule": "10 3 * * *", "human": "Daily at 03:10",
         "command": "test -e /run/systemd/system || SERVICE_MODE=1 /sbin/e2scrub_all -A -r", "next": iso(at(3, 10)), "last": None},
    ]
    timers = [{"unit": u, "activates": u.replace(".timer", ".service"), "next": iso(local + timedelta(minutes=m)),
               "last": iso(local - timedelta(hours=h))}
              for u, m, h in (("logrotate.timer", 340, 20), ("apt-daily.timer", 610, 14), ("fstrim.timer", 2900, 120),
                              ("dpkg-db-backup.timer", 300, 23), ("systemd-tmpfiles-clean.timer", 900, 9))]
    return {"jobs": sorted(jobs, key=lambda j: j["next"]), "timers": sorted(timers, key=lambda t: t["next"]),
            "periodic": {"hourly": [], "daily": ["apt-compat", "dpkg", "logrotate"], "weekly": [], "monthly": []}}


def history_seed():
    """Ten minutes of past samples so the chart isn't empty on first load (demo only)."""
    now, pts = time.time(), []
    for i in range(599, 0, -1):
        t = now - i
        r = max(0, rate_at(t) + random.uniform(-4, 4))
        pts.append({"t": t * 1000, "req": r, "e5": r * .0005 * random.uniform(0, 3),
                    "rx": r * 900, "tx": r * 16000, "cpu": wave(t, 60, 8, 30)})
    return pts


SEED_JS = """<script>
/* demo: pre-fill the chart history and render the first frame immediately */
(() => {
  const seed = %s, snap = %s;
  for (const p of seed) { hist.t.push(new Date(p.t)); hist.req.push(p.req); hist.e5.push(p.e5);
                          hist.rx.push(p.rx); hist.tx.push(p.tx); hist.cpu.push(p.cpu); hist.deny.push(0); }
  const theme = new URLSearchParams(location.search).get("theme");
  if (theme) setTheme(theme);
  snap.sys.haproxy = snap.info; render(snap.rows, snap.sys); applySettings(snap.settings, snap.sys); setLive(true, "Live");
  prev.at = snap.ts;   // counters in this frame were taken at snap.ts, not "now"
  // ?static=1 freezes the first frame (used for README screenshots)
  if (new URLSearchParams(location.search).has("static")) { signedOut = true; disconnect(); }
})();
</script>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, ctype, body):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def page(self, name):
        with open(os.path.join(PANEL, name), encoding="utf-8") as f:
            html = f.read().replace("__SERVER_NAME__", NAME).replace("__APP_ID__", "demo")
        if name == "index.html":
            html = html.replace("</body>", SEED_JS % (json.dumps(history_seed()), json.dumps(snapshot())) + "</body>")
        return html

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/hapanel"):
            self.send_response(302); self.send_header("Location", "/hapanel/"); self.end_headers()
        elif path == "/hapanel/":
            self.send(200, "text/html; charset=utf-8", self.page("index.html"))
        elif path == "/hapanel/login":
            self.send(200, "text/html; charset=utf-8", self.page("login.html"))
        elif path == "/hapanel/session":
            self.send(204, "text/plain", b"")
        elif path in STATIC:
            with open(os.path.join(PANEL, path.rsplit("/", 1)[1]), "rb") as f:
                body = f.read()
            if path.endswith(".webmanifest"):
                body = body.replace(b"__SERVER_NAME__", NAME.encode()).replace(b"__APP_ID__", b"demo")
            self.send(200, STATIC[path], body)
        elif path == "/hapanel/live":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(b"retry: 2000\n\n")
                while True:
                    self.wfile.write(f"data: {json.dumps(snapshot())}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send(404, "text/plain", "not found\n")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        path = self.path.split("?")[0]
        if path == "/hapanel/settings":
            self.send(200, "application/json", json.dumps({"name": NAME}))
        elif path in ("/hapanel/login", "/hapanel/logout", "/hapanel/password"):
            self.send(200, "application/json", '{"ok":true}')
        else:
            self.send(404, "application/json", '{"error":"not found"}')


if __name__ == "__main__":
    print(f"HAPanel demo: http://localhost:{PORT}/hapanel/  (simulated data, any password works)")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
