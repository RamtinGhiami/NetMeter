"""Local HTTP server: serves the Persian dashboard and a small JSON API."""
from __future__ import annotations

import json
import mimetypes
import os
import sys
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, unquote, urlparse

from .collector import Collector, now_date
from .config import Config
from .db import Database, billing_month_start
from .routers import RouterError, build_adapter
from .util import day_str


def web_dir() -> Path:
    if getattr(sys, "frozen", False):
        base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
        candidate = base / "web"
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent / "web"


class Api:
    def __init__(self, config: Config, db: Database, collector: Collector, demo: bool = False):
        self.config = config
        self.db = db
        self.collector = collector
        self.demo = demo
        self._started = time.time()
        self._test_failures = 0
        self._test_block_until = 0.0

    # ---- endpoints ---------------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        data = self.collector.snapshot()
        data["app"] = {
            "version": "0.1.0",
            "uptime": int(time.time() - self._started),
            "platform": sys.platform,
            "demo": self.demo,
        }
        return data

    def update_config(self, payload: dict[str, Any]) -> dict[str, Any]:
        before = (self.config.router_url, self.config.username, self.config.poll_interval)
        self.config.patch(payload)
        self.config.save()
        if "start_with_windows" in payload:
            try:
                from .autostart import apply_autostart
                apply_autostart(self.config.start_with_windows, str(self.config.data_dir))
            except Exception:
                pass
        if ((self.config.router_url, self.config.username, self.config.poll_interval) != before
                or "password" in payload):
            self.collector.reset_adapter()
            self.collector.reset_auth_backoff()
        self.collector.wake()
        return {"ok": True, "config": self.config.public()}

    def test(self, payload: dict[str, Any]) -> dict[str, Any]:
        """One-shot login + read, using form values without saving them."""
        if self.demo:
            raise RouterError("demo", "در حالت نمایشی، تست اتصال غیرفعال است", "setup")
        now = time.time()
        if now < self._test_block_until:
            left = int(self._test_block_until - now) + 1
            raise RouterError("wait", f"برای محافظت از مودم، {left} ثانیه دیگر دوباره تلاش کنید", "locked")
        url = str(payload.get("router_url") or self.config.router_url or "")
        user = str(payload.get("username") or self.config.username or "admin")
        password = str(payload.get("password") or self.config.password or "")
        if not url:
            raise RouterError("setup", "آدرس مودم خالی است", "setup")
        if not password:
            raise RouterError("nopass", "رمز عبور مودم وارد نشده است", "auth")
        adapter = build_adapter(url, user, password, timeout=15)
        if adapter is None:
            raise RouterError("setup", "آداپتر مناسبی پیدا نشد", "setup")
        try:
            result = adapter.test()
            self._test_failures = 0
            return result
        except RouterError as exc:
            if exc.kind in ("auth", "locked", "busy"):
                self._test_failures += 1
                self._test_block_until = time.time() + min(600, 45 * (2 ** (self._test_failures - 1)))
            raise

    def device_history(self, mac: str, days: int) -> dict[str, Any]:
        dev = self.db.device_by_mac(mac)
        if not dev:
            return {"ok": False, "error": "not found"}
        dev["display_name"] = dev.get("custom_name") or dev.get("hostname") or ""
        return {
            "ok": True,
            "device": dev,
            "days": days,
            "history": self.db.device_history(mac, days),
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "NetMeter/0.1"
    protocol_version = "HTTP/1.1"

    # populated by serve()
    api: Api

    # ---- plumbing ----------------------------------------------------
    def log_message(self, fmt: str, *args) -> None:  # reduce console noise
        if os.environ.get("NETMETER_DEBUG"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _host_ok(self) -> bool:
        origin = self.headers.get("Origin") or ""
        if not origin:
            return True
        host = self.headers.get("Host") or ""
        try:
            o = urlparse(origin)
            allowed = {"127.0.0.1", "localhost", "::1", "[::1]"}
            if o.hostname in allowed:
                return True
            return bool(host) and origin.endswith(host)
        except Exception:
            return False

    def _json(self, obj: Any, status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _text(self, text: str, ctype: str = "text/plain; charset=utf-8",
              status: int = 200, extra: Optional[dict[str, str]] = None) -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > 1_000_000:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            return {}
        return data if isinstance(data, dict) else {}

    # ---- routes ------------------------------------------------------
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)
        try:
            if path.startswith("/api/"):
                if not self._host_ok():
                    return self._json({"ok": False, "error": "forbidden"}, 403)
                return self._api_get(path, query)
            return self._static(path)
        except BrokenPipeError:
            pass
        except Exception as exc:
            self._json({"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}, 500)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        try:
            if not self._host_ok():
                return self._json({"ok": False, "error": "forbidden"}, 403)
            payload = self._read_json()
            return self._api_post(unquote(parsed.path), payload)
        except BrokenPipeError:
            pass
        except RouterError as exc:
            self._json({"ok": False, "error": str(exc), "kind": exc.kind, "code": exc.code}, 400)
        except Exception as exc:
            self._json({"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}, 500)

    # ---- API ---------------------------------------------------------
    def _api_get(self, path: str, query: dict[str, list[str]]) -> None:
        api = self.api
        if path == "/api/snapshot":
            return self._json(api.snapshot())
        if path == "/api/config":
            return self._json({"ok": True, "config": api.config.public()})
        if path == "/api/events":
            return self._json({"ok": True, "events": api.db.recent_events(100)})
        if path == "/api/health":
            return self._json({"ok": True, "status": api.collector.status})
        if path.startswith("/api/device/"):
            rest = path[len("/api/device/"):]
            parts = rest.split("/")
            mac = parts[0]
            days = 30
            if len(parts) > 1 and parts[1] == "history":
                try:
                    days = max(1, min(365, int((query.get("days") or ["30"])[0])))
                except ValueError:
                    days = 30
            return self._json(api.device_history(mac, days))
        if path == "/api/export/devices.csv":
            today = day_str()
            month = billing_month_start(now_date(), api.config.reset_day).isoformat()
            csv_text = api.db.export_devices_csv(today, month)
            return self._text(csv_text, "text/csv; charset=utf-8", extra={
                "Content-Disposition": 'attachment; filename="netmeter-devices.csv"',
            })
        if path == "/api/export/wan.csv":
            csv_text = api.db.export_wan_csv(180)
            return self._text(csv_text, "text/csv; charset=utf-8", extra={
                "Content-Disposition": 'attachment; filename="netmeter-wan.csv"',
            })
        return self._json({"ok": False, "error": "not found"}, 404)

    def _api_post(self, path: str, payload: dict[str, Any]) -> None:
        api = self.api
        if path == "/api/config":
            return self._json(api.update_config(payload))
        if path == "/api/poll":
            api.collector.wake()
            return self._json({"ok": True})
        if path == "/api/test":
            return self._json(api.test(payload))
        if path == "/api/device/meta":
            mac = str(payload.get("mac") or "").strip()
            if not mac:
                return self._json({"ok": False, "error": "mac لازم است"}, 400)
            name = payload.get("name")
            category = payload.get("category")
            dev = api.db.set_device_meta(
                mac,
                None if name is None else str(name),
                None if category is None else str(category),
            )
            if dev is None:
                return self._json({"ok": False, "error": "not found"}, 404)
            label = dev.get("custom_name") or dev.get("hostname") or mac
            api.db.log_event("info", f"نام/دسته‌ی دستگاه «{label}» به‌روزرسانی شد")
            return self._json({"ok": True, "device": dev})
        if path == "/api/clear":
            api.db.clear_all()
            api.collector.reset_adapter()
            api.db.log_event("warn", "تاریخچه‌ی مصرف پاک شد")
            return self._json({"ok": True})
        if path == "/api/quit":
            api.db.log_event("info", "برنامه از طریق داشبورد بسته شد")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return self._json({"ok": True})
        if path == "/api/event":
            level = str(payload.get("level") or "info")[:10]
            msg = str(payload.get("message") or "")[:400]
            if msg:
                api.db.log_event(level, msg)
            return self._json({"ok": True})
        return self._json({"ok": False, "error": "not found"}, 404)

    # ---- static ------------------------------------------------------
    def _static(self, path: str) -> None:
        root = web_dir()
        rel = path.lstrip("/") or "index.html"
        if ".." in rel or rel.startswith("/") or "\\" in rel:
            return self._text("not found", status=404)
        target = (root / rel).resolve()
        if root.resolve() not in target.parents and target != root.resolve():
            return self._text("not found", status=404)
        if target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            # SPA-ish fallback is not needed; serve a friendly 404
            return self._text("not found", status=404)
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
            ctype += "; charset=utf-8"
        body = target.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)


def serve(config: Config, db: Database, collector: Collector,
          open_browser: bool = True, demo: bool = False) -> ThreadingHTTPServer:
    Handler.api = Api(config, db, collector, demo=demo)
    httpd = ThreadingHTTPServer((config.bind_host, config.port), Handler)
    httpd.daemon_threads = True

    def _open() -> None:
        host = config.bind_host if config.bind_host not in ("0.0.0.0", "") else "127.0.0.1"
        time.sleep(0.6)
        try:
            webbrowser.open(f"http://{host}:{config.port}/")
        except Exception:
            pass

    if open_browser:
        threading.Thread(target=_open, daemon=True).start()
    return httpd
