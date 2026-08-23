#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import secrets
import socketserver
import subprocess
import threading
import time
import fcntl
from http.server import BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "scripts" / "run-media-stack-update.sh"
SOCKET_PATH = Path(os.environ.get("MEDIA_UPDATE_BROKER_SOCKET", str(Path.home() / ".local/run/chae-media-update/broker.sock")))
STATE_FILE = Path(os.environ.get("MEDIA_UPDATE_STATE_DIR", str(Path.home() / ".local/state/chae-media-update"))) / "current.json"
QUEUE_LOCK_FILE = STATE_FILE.parent / "queue.lock"
SECRET_FILE = Path(os.environ.get("UPDATE_BROKER_SECRET_FILE", str(ROOT / "jellyfin-whatsapp-bot/auth/update-broker.secret")))


def load_secret():
    configured = os.environ.get("UPDATE_BROKER_SECRET", "")
    if configured:
        return configured.encode()
    try:
        return SECRET_FILE.read_text().strip().encode()
    except OSError:
        return b""


SECRET = load_secret()
MAX_SKEW_SECONDS = 60
NONCE_TTL_SECONDS = 120
used_nonces = {}
nonce_lock = threading.Lock()
process_lock = threading.Lock()
active_process = None


def valid_secret():
    return len(SECRET) >= 32 and not SECRET.startswith(b"CHANGEME")


def authenticate(handler, body):
    if not valid_secret():
        return False
    timestamp = handler.headers.get("x-update-timestamp", "")
    nonce = handler.headers.get("x-update-nonce", "")
    signature = handler.headers.get("x-update-signature", "")
    try:
        timestamp_number = int(timestamp)
    except ValueError:
        return False
    now = int(time.time())
    if abs(now - timestamp_number) > MAX_SKEW_SECONDS or not (16 <= len(nonce) <= 64):
        return False
    payload = b"\n".join([
        timestamp.encode(),
        nonce.encode(),
        handler.command.encode(),
        handler.path.encode(),
        body,
    ])
    expected = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        return False
    with nonce_lock:
        expired = [value for value, seen_at in used_nonces.items() if now - seen_at > NONCE_TTL_SECONDS]
        for value in expired:
            used_nonces.pop(value, None)
        if nonce in used_nonces:
            return False
        used_nonces[nonce] = now
    return True


def load_status():
    try:
        return json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"status": "idle", "phase": "idle", "completed": []}


def write_starting_status(job_id):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_name(f".current.{secrets.token_hex(4)}")
    temporary.write_text(json.dumps({
        "id": job_id,
        "status": "starting",
        "phase": "starting",
        "current": "",
        "message": "Reservando la cola de actualización",
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "completed": [],
    }, separators=(",", ":")))
    temporary.replace(STATE_FILE)


def process_running():
    global active_process
    with process_lock:
        if active_process is not None and active_process.poll() is None:
            return True
        if active_process is not None:
            active_process = None
    QUEUE_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(QUEUE_LOCK_FILE, "a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock_file, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        lock_file.close()


class UpdateHandler(BaseHTTPRequestHandler):
    server_version = "ChaeMediaUpdateBroker/1"

    def log_message(self, format_string, *args):
        print(f"[broker] {format_string % args}", flush=True)

    def respond(self, status, payload):
        encoded = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def read_body(self):
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            return None
        if length < 0 or length > 4096:
            return None
        return self.rfile.read(length)

    def handle_request(self):
        body = self.read_body()
        if body is None:
            self.respond(413, {"ok": False, "error": "invalid_body"})
            return
        if not authenticate(self, body):
            self.respond(401, {"ok": False, "error": "unauthorized"})
            return

        if self.command == "GET" and self.path == "/v1/status":
            self.respond(200, {"ok": True, "job": load_status()})
            return

        if self.command == "POST" and self.path == "/v1/preview":
            if process_running():
                self.respond(409, {"ok": False, "error": "update_running"})
                return
            try:
                runner_source = RUNNER.read_text()
                result = subprocess.run(
                    ["/usr/bin/bash", "-s", "--", "preview"],
                    cwd=ROOT,
                    input=runner_source,
                    env={**os.environ, "MEDIA_UPDATE_ROOT": str(ROOT)},
                    capture_output=True,
                    text=True,
                    timeout=300,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                self.respond(500, {"ok": False, "error": "preview_failed", "message": str(error)})
                return
            if result.returncode != 0:
                message = (result.stderr or result.stdout or "preflight failed").strip().splitlines()[-1]
                self.respond(409, {"ok": False, "error": "preflight_failed", "message": message[:500]})
                return
            try:
                preview = json.loads(result.stdout)
            except json.JSONDecodeError:
                self.respond(500, {"ok": False, "error": "invalid_preview"})
                return
            self.respond(200, preview)
            return

        if self.command == "POST" and self.path == "/v1/start":
            global active_process
            try:
                request_data = json.loads(body or b"{}")
            except json.JSONDecodeError:
                self.respond(400, {"ok": False, "error": "invalid_json"})
                return
            if not isinstance(request_data, dict):
                self.respond(400, {"ok": False, "error": "invalid_approved_commit"})
                return
            approved_commit = request_data.get("approvedCommit", "")
            approved_tree_hash = request_data.get("approvedTreeHash", "")
            valid_commit = isinstance(approved_commit, str) and len(approved_commit) == 40 and all(character in "0123456789abcdef" for character in approved_commit)
            valid_tree_hash = isinstance(approved_tree_hash, str) and len(approved_tree_hash) == 64 and all(character in "0123456789abcdef" for character in approved_tree_hash)
            if len(request_data) != 2 or not valid_commit or not valid_tree_hash:
                self.respond(400, {"ok": False, "error": "invalid_approved_commit"})
                return
            if process_running():
                self.respond(409, {"ok": False, "error": "update_running"})
                return
            with process_lock:
                if active_process is not None and active_process.poll() is None:
                    self.respond(409, {"ok": False, "error": "update_running"})
                    return
                job_id = secrets.token_hex(8)
                QUEUE_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
                queue_lock = open(QUEUE_LOCK_FILE, "a+")
                try:
                    fcntl.flock(queue_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    queue_lock.close()
                    self.respond(409, {"ok": False, "error": "update_running"})
                    return
                log_dir = ROOT / "logs"
                log_dir.mkdir(exist_ok=True)
                broker_log = open(log_dir / f"media-stack-broker-{job_id}.log", "ab", buffering=0)
                try:
                    runner_source = RUNNER.read_bytes()
                    child_env = {
                        **os.environ,
                        "MEDIA_UPDATE_ROOT": str(ROOT),
                        "UPDATE_QUEUE_LOCK_FD": str(queue_lock.fileno()),
                    }
                    write_starting_status(job_id)
                    active_process = subprocess.Popen(
                        ["/usr/bin/bash", "-s", "--", "run", job_id, approved_commit, approved_tree_hash],
                        cwd=ROOT,
                        stdin=subprocess.PIPE,
                        env=child_env,
                        pass_fds=(queue_lock.fileno(),),
                        stdout=broker_log,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                    active_process.stdin.write(runner_source)
                    active_process.stdin.close()
                except OSError as error:
                    queue_lock.close()
                    broker_log.close()
                    self.respond(500, {"ok": False, "error": "start_failed", "message": str(error)})
                    return
                queue_lock.close()
            self.respond(202, {"ok": True, "jobId": job_id, "status": "started"})
            return

        self.respond(404, {"ok": False, "error": "not_found"})

    do_GET = handle_request
    do_POST = handle_request


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    if not valid_secret():
        raise SystemExit("UPDATE_BROKER_SECRET must contain at least 32 non-placeholder characters")
    SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()
    server = UnixHTTPServer(str(SOCKET_PATH), UpdateHandler)
    os.chmod(SOCKET_PATH, 0o660)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        SOCKET_PATH.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
