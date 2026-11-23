"""Entry point: python -m netmeter [--no-browser] [--port 8787] [--once]."""
from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import socket
import sys
import webbrowser
from pathlib import Path

from . import __version__
from .collector import Collector
from .config import Config, default_data_dir
from .db import Database
from .server import serve


def _setup_logging(data_dir: Path) -> None:
    data_dir.mkdir(parents=True, exist_ok=True)
    log = logging.getLogger()
    if log.handlers:
        return
    log.setLevel(logging.INFO)
    handler = logging.handlers.RotatingFileHandler(
        data_dir / "netmeter.log", maxBytes=1_000_000, backupCount=3, encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    log.addHandler(handler)
    if os.environ.get("NETMETER_DEBUG"):
        stream = logging.StreamHandler(sys.stderr)
        stream.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
        log.addHandler(stream)


def _port_busy(host: str, port: int) -> bool:
    probe_host = "127.0.0.1" if host in ("0.0.0.0", "") else host
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.4)
        return s.connect_ex((probe_host, port)) == 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="netmeter",
        description="اینترنت‌متر — پایش مصرف اینترنت دستگاه‌ها از روی مودم",
    )
    parser.add_argument("--port", type=int, default=0, help="پورت وب (پیش‌فرض 8787)")
    parser.add_argument("--host", default="", help="آدرس اتصال وب (پیش‌فرض 127.0.0.1)")
    parser.add_argument("--data-dir", default="", help="پوشه‌ی ذخیره‌ی داده‌ها")
    parser.add_argument("--no-browser", action="store_true", help="مرورگر را باز نکن")
    parser.add_argument("--once", action="store_true", help="فقط یک بار بخوان و خارج شو")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--version", action="version", version=f"NetMeter {__version__}")
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir).expanduser() if args.data_dir else default_data_dir()
    _setup_logging(data_dir)
    config = Config(data_dir)
    if args.port:
        config.port = max(1024, min(65535, args.port))
    if args.host:
        config.bind_host = args.host

    db = Database(config.data_dir / "netmeter.db")
    collector = Collector(config, db)

    demo_mode = args.demo
    if demo_mode:
        from . import demo
        if not db.query_one("SELECT 1 FROM devices LIMIT 1"):
            demo.seed(db)
        if not config.router_url:
            config.router_url = "https://192.168.70.1"
        config.set_password("demo")
        config.save()
        collector.status.update(demo.demo_status())

    if args.once:
        ok = collector.poll_once()
        out = {
            "ok": ok,
            "status": collector.status,
            "snapshot": collector.snapshot(),
        }
        print(json.dumps(out, ensure_ascii=False, indent=2, default=str))
        db.close()
        return 0 if ok else 1

    if _port_busy(config.bind_host, config.port):
        host = config.bind_host if config.bind_host not in ("0.0.0.0", "") else "127.0.0.1"
        print(f"NetMeter already running on http://{host}:{config.port}/")
        if not args.no_browser:
            webbrowser.open(f"http://{host}:{config.port}/")
        db.close()
        return 0

    if not demo_mode:
        collector.start()
    httpd = serve(config, db, collector, open_browser=not args.no_browser, demo=demo_mode)
    host = config.bind_host if config.bind_host not in ("0.0.0.0", "") else "127.0.0.1"
    print(f"NetMeter {__version__} running on http://{host}:{config.port}/  (Ctrl+C to stop)")
    db.log_event("info", f"برنامه اجرا شد — نسخه {__version__}")
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        print("\nStopping…")
    finally:
        collector.stop()
        httpd.shutdown()
        httpd.server_close()
        db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
