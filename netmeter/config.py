"""Configuration and data-directory handling."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from . import dpapi

APP_NAME = "NetMeter"
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def default_data_dir() -> Path:
    env = os.environ.get("NETMETER_DATA")
    if env:
        return Path(env).expanduser()
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent / "data"
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / APP_NAME
    return Path.home() / f".{APP_NAME.lower()}"


def detect_gateway() -> str:
    """Best-effort IPv4 default gateway detection on Windows."""
    if os.name == "nt":
        try:
            out = subprocess.run(
                ["route", "print", "0.0.0.0"],
                capture_output=True, text=True, encoding="mbcs", errors="ignore",
                creationflags=CREATE_NO_WINDOW, timeout=8,
            ).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[0] == "0.0.0.0" and parts[1] == "0.0.0.0":
                    ip = parts[2]
                    if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip) and not ip.startswith("0."):
                        return ip
        except Exception:
            pass
        try:
            out = subprocess.run(
                ["ipconfig"],
                capture_output=True, text=True, encoding="mbcs", errors="ignore",
                creationflags=CREATE_NO_WINDOW, timeout=8,
            ).stdout
            for m in re.finditer(r"(?:Default Gateway|Gateway|دروازه).*?:\s*(\d{1,3}(?:\.\d{1,3}){3})", out):
                if not m.group(1).startswith("0."):
                    return m.group(1)
        except Exception:
            pass
    return ""


def normalize_router_url(url: str) -> str:
    url = (url or "").strip()
    if not url:
        return ""
    if "://" not in url:
        url = "https://" + url
    url = url.rstrip("/")
    # Keep scheme://host[:port] only
    m = re.match(r"^(https?)://([^/]+)", url, re.I)
    if m:
        return f"{m.group(1).lower()}://{m.group(2)}"
    return url


class Config:
    def __init__(self, data_dir: Path | None = None):
        self.data_dir = Path(data_dir) if data_dir else default_data_dir()
        self.path = self.data_dir / "config.json"
        self.router_url: str = ""
        self.username: str = "admin"
        self.password_enc: str = ""
        self.poll_interval: int = 10
        self.quota_gb: float = 0.0
        self.reset_day: int = 0
        self.bind_host: str = "127.0.0.1"
        self.port: int = 8787
        self.offline_after_min: int = 5
        self.start_with_windows: bool = False
        self.theme: str = "dark"
        self.load()

    # ---- persistence -------------------------------------------------
    def ensure_dir(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)

    def load(self) -> None:
        self.ensure_dir()
        data: dict[str, Any] = {}
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        self.router_url = normalize_router_url(str(data.get("router_url") or ""))
        self.username = str(data.get("username") or "admin").strip() or "admin"
        self.password_enc = str(data.get("password_enc") or "")
        self.poll_interval = max(5, min(3600, int(data.get("poll_interval") or 10)))
        try:
            self.quota_gb = max(0.0, float(data.get("quota_gb") or 0))
        except Exception:
            self.quota_gb = 0.0
        try:
            self.reset_day = max(0, min(31, int(data.get("reset_day") or 0)))
        except Exception:
            self.reset_day = 0
        self.bind_host = str(data.get("bind_host") or "127.0.0.1")
        try:
            self.port = int(data.get("port") or 8787)
        except Exception:
            self.port = 8787
        try:
            self.offline_after_min = max(1, min(120, int(data.get("offline_after_min") or 5)))
        except Exception:
            self.offline_after_min = 5
        self.start_with_windows = bool(data.get("start_with_windows") or False)
        self.theme = str(data.get("theme") or "dark")
        if not self.router_url:
            gw = detect_gateway()
            if gw:
                self.router_url = f"https://{gw}"

    def save(self) -> None:
        self.ensure_dir()
        payload = {
            "router_url": self.router_url,
            "username": self.username,
            "password_enc": self.password_enc,
            "poll_interval": self.poll_interval,
            "quota_gb": self.quota_gb,
            "reset_day": self.reset_day,
            "bind_host": self.bind_host,
            "port": self.port,
            "offline_after_min": self.offline_after_min,
            "start_with_windows": self.start_with_windows,
            "theme": self.theme,
        }
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self.path)

    # ---- password ----------------------------------------------------
    @property
    def password(self) -> str:
        try:
            return dpapi.unprotect(self.password_enc)
        except Exception:
            return ""

    def set_password(self, plain: str) -> None:
        self.password_enc = dpapi.protect(plain) if plain else ""

    # ---- API views ---------------------------------------------------
    def public(self) -> dict[str, Any]:
        return {
            "router_url": self.router_url,
            "username": self.username,
            "password_set": bool(self.password),
            "poll_interval": self.poll_interval,
            "quota_gb": self.quota_gb,
            "reset_day": self.reset_day,
            "bind_host": self.bind_host,
            "port": self.port,
            "offline_after_min": self.offline_after_min,
            "start_with_windows": self.start_with_windows,
            "theme": self.theme,
            "data_dir": str(self.data_dir),
            "needs_setup": not (self.router_url and self.password),
        }

    def patch(self, data: dict[str, Any]) -> None:
        if "router_url" in data:
            url = normalize_router_url(str(data.get("router_url") or ""))
            if not url:
                gw = detect_gateway()
                url = f"https://{gw}" if gw else ""
            self.router_url = url
        if "username" in data:
            self.username = (str(data.get("username") or "").strip() or "admin")
        if "password" in data and data.get("password"):
            self.set_password(str(data["password"]))
        if data.get("clear_password"):
            self.password_enc = ""
        if "poll_interval" in data:
            try:
                self.poll_interval = max(5, min(3600, int(data["poll_interval"])))
            except Exception:
                pass
        if "quota_gb" in data:
            try:
                self.quota_gb = max(0.0, float(data["quota_gb"] or 0))
            except Exception:
                pass
        if "reset_day" in data:
            try:
                self.reset_day = max(0, min(31, int(data["reset_day"] or 0)))
            except Exception:
                pass
        if "bind_host" in data:
            host = str(data.get("bind_host") or "127.0.0.1")
            self.bind_host = host if host in ("127.0.0.1", "0.0.0.0", "localhost") else "127.0.0.1"
        if "port" in data:
            try:
                self.port = max(1024, min(65535, int(data["port"])))
            except Exception:
                pass
        if "offline_after_min" in data:
            try:
                self.offline_after_min = max(1, min(120, int(data["offline_after_min"])))
            except Exception:
                pass
        if "start_with_windows" in data:
            self.start_with_windows = bool(data["start_with_windows"])
        if "theme" in data:
            self.theme = str(data.get("theme") or "dark")

    def router_candidates(self) -> list[str]:
        """HTTPS first, HTTP fallback, for the configured host."""
        base = self.router_url
        if not base:
            return []
        out = [base]
        if base.startswith("https://"):
            out.append("http://" + base[len("https://"):])
        elif base.startswith("http://"):
            out.append("https://" + base[len("http://"):])
        return out
