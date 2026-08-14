#!/usr/bin/env python3
"""Small authenticated broker for Grok-style shared desktop assignments."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
DATA = Path(os.environ.get("BOX_DATA", "/data"))
SOCKET_DIR = Path(os.environ.get("BOX_SOCKET_DIR", "/run/hermes-box"))
ASSIGNMENTS = DATA / "assignments.json"
MAX_SESSIONS = int(os.environ.get("BOX_MAX_SESSIONS", "12"))
PUBLIC_HOST = os.environ.get("BOX_PUBLIC_HOST", "127.0.0.1")
TOKEN = os.environ.get("BOX_BROKER_TOKEN", "")
BIND = os.environ.get("BOX_BROKER_BIND", "0.0.0.0")
PORT = int(os.environ.get("BOX_BROKER_PORT", "8787"))


class SessionManager:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.processes: dict[str, subprocess.Popen[bytes]] = {}
        DATA.mkdir(parents=True, exist_ok=True)
        SOCKET_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(SOCKET_DIR, 0o777)
        self.assignments = self._load()

    def _load(self) -> dict[str, int]:
        try:
            raw = json.loads(ASSIGNMENTS.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}
        if not isinstance(raw, dict):
            return {}
        valid: dict[str, int] = {}
        used: set[int] = set()
        for profile, slot in sorted(raw.items()):
            if PROFILE_RE.fullmatch(profile) and isinstance(slot, int) and 0 <= slot < MAX_SESSIONS and slot not in used:
                valid[profile] = slot
                used.add(slot)
        return valid

    def _save(self) -> None:
        tmp = ASSIGNMENTS.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.assignments, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, ASSIGNMENTS)

    def _slot(self, profile: str) -> int:
        if not PROFILE_RE.fullmatch(profile):
            raise ValueError("invalid profile name")
        existing = self.assignments.get(profile)
        if existing is not None:
            return existing
        used = set(self.assignments.values())
        for slot in range(MAX_SESSIONS):
            if slot not in used:
                self.assignments[profile] = slot
                self._save()
                return slot
        raise RuntimeError("no desktop monitor is available")

    def _alive(self, profile: str) -> bool:
        process = self.processes.get(profile)
        return process is not None and process.poll() is None

    def details(self, profile: str) -> dict[str, object]:
        slot = self.assignments[profile]
        socket = SOCKET_DIR / f"{profile}.sock"
        return {
            "profile": profile,
            "slot": slot,
            "display": f":{10 + slot}",
            "viewer_port": 6080 + slot,
            "viewer_url": f"http://{PUBLIC_HOST}:{6080 + slot}/vnc.html?autoconnect=true&resize=scale&reconnect=true",
            "socket": str(socket),
            "running": self._alive(profile),
            "ready": self._alive(profile) and socket.is_socket(),
        }

    def ensure(self, profile: str) -> dict[str, object]:
        with self.lock:
            slot = self._slot(profile)
            if not self._alive(profile):
                socket = SOCKET_DIR / f"{profile}.sock"
                socket.unlink(missing_ok=True)
                process = subprocess.Popen(
                    ["/usr/local/bin/start-forever-box-session", profile, str(slot)],
                    start_new_session=True,
                )
                self.processes[profile] = process
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = self.details(profile)
            if state["ready"]:
                return state
            if not state["running"]:
                raise RuntimeError("desktop session exited during startup")
            time.sleep(0.2)
        raise TimeoutError("desktop session did not become ready")

    def stop(self, profile: str) -> dict[str, object]:
        with self.lock:
            if profile not in self.assignments:
                raise KeyError(profile)
            process = self.processes.pop(profile, None)
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            (SOCKET_DIR / f"{profile}.sock").unlink(missing_ok=True)
            return self.details(profile)

    def restore(self) -> None:
        for profile in list(self.assignments):
            try:
                self.ensure(profile)
            except Exception as exc:  # startup remains available for repair
                print(f"failed to restore {profile}: {exc}", flush=True)


manager = SessionManager()


class Handler(BaseHTTPRequestHandler):
    server_version = "HermesForeverBox/1"

    def _headers(self, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Box-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.end_headers()

    def _json(self, payload: object, status: int = 200) -> None:
        self._headers(status)
        self.wfile.write(json.dumps(payload).encode())

    def _authorized(self) -> bool:
        if not TOKEN:
            return True
        return self.headers.get("Authorization") == f"Bearer {TOKEN}" or self.headers.get("X-Box-Token") == TOKEN

    def _profile(self) -> str | None:
        match = re.fullmatch(r"/v1/profiles/([^/]+)(?:/ensure)?", urlparse(self.path).path)
        return match.group(1) if match else None

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._headers(HTTPStatus.NO_CONTENT)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._json({"ok": True, "sessions": len(manager.assignments)})
            return
        if not self._authorized():
            self._json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        if path == "/v1/profiles":
            self._json({"profiles": [manager.details(name) for name in sorted(manager.assignments)]})
            return
        profile = self._profile()
        if profile and profile in manager.assignments:
            self._json(manager.details(profile))
            return
        self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        profile = self._profile()
        try:
            if profile is None or not urlparse(self.path).path.endswith("/ensure"):
                raise KeyError(profile)
            self._json(manager.ensure(profile))
        except ValueError as exc:
            self._json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except KeyError:
            self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)
        except (RuntimeError, TimeoutError) as exc:
            self._json({"error": str(exc)}, HTTPStatus.CONFLICT)

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            self._json({"error": "unauthorized"}, HTTPStatus.UNAUTHORIZED)
            return
        profile = self._profile()
        try:
            if profile is None:
                raise KeyError(profile)
            self._json(manager.stop(profile))
        except KeyError:
            self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"broker: {fmt % args}", flush=True)


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("BOX_BROKER_TOKEN is required")
    threading.Thread(target=manager.restore, daemon=True).start()
    print(f"forever-box broker listening on {BIND}:{PORT}", flush=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
