#!/usr/bin/env python3
"""API HTTP minima para disparar la limpieza del stack desde el panel Homepage.

Rutas:
  GET /        -> estado JSON
  GET /clean   -> ejecuta cleanup-stack.sh y devuelve resumen (text/plain)
  GET /clean?dry=1 -> dry-run

Escucha en 0.0.0.0:3655 (solo red LAN).
"""

import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

CLEANUP_SCRIPT = Path.home() / "scripts" / "cleanup-stack.sh"
STATE_DIR = Path.home() / ".local/state/cleanup-stack"
LAST_RUN_FILE = STATE_DIR / "last-run.json"
LOCK_FILE = STATE_DIR / "cleanup.lock"
LISTEN_PORT = 3655
CLEANUP_TIMEOUT = 900


class CleanupHandler(BaseHTTPRequestHandler):
    server_version = "chae-cleanup-api/1.0"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

    def _send(self, code, body, content_type="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send(200, self._status())
        elif parsed.path == "/clean":
            self._clean()
        else:
            self._send(404, {"error": "ruta no encontrada"})

    def do_POST(self):
        self._send(405, {"error": "solo GET"})

    def _status(self):
        last_run = None
        if LAST_RUN_FILE.exists():
            try:
                last_run = json.loads(LAST_RUN_FILE.read_text())
            except (ValueError, OSError):
                last_run = None
        return json.dumps(
            {"ok": True, "service": "cleanup-api", "running": _busy(), "lastRun": last_run}
        )

    def _clean(self):
        query = parse_qs(urlparse(self.path).query)
        import os

        env = dict(os.environ)
        env["DRY_RUN"] = "1" if query.get("dry", ["0"])[0] in ("1", "true") else "0"
        try:
            result = subprocess.run(
                [str(CLEANUP_SCRIPT)],
                capture_output=True,
                text=True,
                timeout=CLEANUP_TIMEOUT,
                env=env,
            )
            out = result.stdout.strip()
            if result.returncode == 75:
                self._send(409, "ERROR: ya hay una limpieza en ejecucion\n", "text/plain")
                return
            if result.returncode != 0:
                self._send(500, f"ERROR (exit {result.returncode}):\n{out}\n{result.stderr[-2000:]}", "text/plain")
                return
            lines = [ln for ln in out.splitlines() if ln and not ln.startswith("[")]
            summary = "Limpieza del stack:\n" + "\n".join(lines) + "\n"
            self._send(200, summary, "text/plain")
        except subprocess.TimeoutExpired:
            self._send(504, "ERROR: la limpieza excedio el tiempo maximo\n", "text/plain")


def _busy():
    import fcntl
    import os

    if not STATE_DIR.exists():
        return False
    try:
        fd = os.open(str(LOCK_FILE), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        return False
    except BlockingIOError:
        os.close(fd)
        return True


def main():
    if not CLEANUP_SCRIPT.exists():
        print(f"ERROR: no existe {CLEANUP_SCRIPT}", flush=True)
        raise SystemExit(1)
    CLEANUP_SCRIPT.chmod(0o755)
    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), CleanupHandler)
    print(f"cleanup-api escuchando en 0.0.0.0:{LISTEN_PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
