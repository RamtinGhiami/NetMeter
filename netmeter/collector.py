"""Background collector: polls the router and turns cumulative counters into usage."""
from __future__ import annotations

import socket
import threading
import time
import traceback
from typing import Any, Optional
from urllib.parse import urlparse

from .config import Config
from .db import Database, billing_month_start
from .routers import HostStat, RouterAdapter, RouterError, build_adapter
from .util import day_str, mac_norm, now_ts, vendor_for_mac

# A counter that jumps backwards is a reboot/reset; keep the new part only.
MAX_SANE_DELTA = 50 * 1024 ** 4   # 50 TB in one poll -> ignore as garbage


class Collector:
    def __init__(self, config: Config, db: Database):
        self.config = config
        self.db = db
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.RLock()
        self._adapter: Optional[RouterAdapter] = None
        self._adapter_key: tuple[str, str, int] = ("", "", -1)
        self._poll_lock = threading.Lock()
        self._last_cleanup = 0
        self._last_info = 0
        self._fail_streak = 0
        self._auth_failures = 0
        self._blocked_until = 0
        self._block_kind = ""
        self._self_ips: set[str] = set()
        self.status: dict[str, Any] = {
            "running": False,
            "polling": False,
            "connected": False,
            "last_poll": 0,
            "last_ok": 0,
            "error": "",
            "error_kind": "",
            "next_poll": 0,
            "poll_count": 0,
            "fail_streak": 0,
            "wan": {},
            "router": {},
            "devices_online": 0,
            "devices_total": 0,
            "adapter": "",
            "blocked_until": 0,
        }

    # ---- lifecycle ---------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="netmeter-collector", daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread:
            self._thread.join(timeout=timeout)

    def wake(self) -> None:
        """Ask the loop to poll now (used by the 'refresh' button)."""
        self._wake.set()

    # ---- adapter -----------------------------------------------------
    def _get_adapter(self) -> Optional[RouterAdapter]:
        cfg = self.config
        if not cfg.router_url or not cfg.password:
            return None
        key = (cfg.router_url, cfg.username, id(cfg))
        if self._adapter is None or self._adapter_key != key:
            adapter = build_adapter(cfg.router_url, cfg.username, cfg.password,
                                    timeout=max(5, min(30, cfg.poll_interval * 2)))
            self._adapter = adapter
            self._adapter_key = key
            self.status["adapter"] = getattr(adapter, "name", "") or ""
        return self._adapter

    def reset_adapter(self) -> None:
        """Force a fresh session next poll (after config changes)."""
        with self._lock:
            self._adapter = None
            self._adapter_key = ("", "", -1)

    def reset_auth_backoff(self) -> None:
        """Called after the user edits credentials: allow one fresh attempt."""
        with self._lock:
            self._auth_failures = 0
            self._blocked_until = 0
            self._block_kind = ""
            self.status["blocked_until"] = 0

    def _detect_self_ips(self) -> set[str]:
        ips: set[str] = set()
        try:
            host = urlparse(self.config.router_url).hostname
            if host:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    s.settimeout(1.0)
                    s.connect((host, 80))
                    ips.add(s.getsockname()[0])
                finally:
                    s.close()
        except Exception:
            pass
        return ips

    # ---- loop --------------------------------------------------------
    def _loop(self) -> None:
        self.status["running"] = True
        self._sleep_until = 0
        while not self._stop.is_set():
            interval = max(5, int(self.config.poll_interval))
            self._wake.clear()
            started = time.time()
            try:
                self.poll_once()
            except Exception:  # never let the thread die
                self.db.log_event("error", "collector crashed: " + traceback.format_exc(limit=3)[:400])
            elapsed = time.time() - started
            wait = max(2.0, interval - elapsed)
            self.status["next_poll"] = int(time.time() + wait)
            self._wake.wait(timeout=wait)
        self.status["running"] = False

    # ---- one poll ----------------------------------------------------
    def poll_once(self) -> bool:
        if not self._poll_lock.acquire(blocking=False):
            return False
        try:
            return self._poll_locked()
        finally:
            self._poll_lock.release()

    def _poll_locked(self) -> bool:
        now = now_ts()
        self.status["polling"] = True
        self.status["last_poll"] = now
        try:
            if now < self._blocked_until:
                left = int(self._blocked_until - now)
                self.status["connected"] = False
                self.status["blocked_until"] = self._blocked_until
                self.status["error_kind"] = self._block_kind or "auth"
                self.status["error"] = (
                    f"برای جلوگیری از قفل شدن مودم، تلاش ورود تا {(left + 59) // 60} دقیقه "
                    "دیگر متوقف است. نام کاربری/رمز را در تنظیمات بررسی کنید."
                )
                return False

            adapter = self._get_adapter()
            if adapter is None:
                self._set_error("setup", "مودم یا رمز عبور تنظیم نشده است")
                return False

            if not self._self_ips:
                self._self_ips = self._detect_self_ips()

            wan = self._poll_wan(adapter, now)
            hosts = self._poll_hosts(adapter, now)

            info = self.status.get("router") or {}
            if now - getattr(self, "_last_info", 0) >= 300:
                try:
                    info = adapter.fetch_info().as_dict()
                    self._last_info = now
                except RouterError:
                    pass

            self.status.update({
                "connected": True,
                "last_ok": now,
                "error": "",
                "error_kind": "",
                "fail_streak": 0,
                "poll_count": int(self.status.get("poll_count") or 0) + 1,
                "wan": wan or {},
                "router": info,
                "devices_online": sum(1 for h in hosts if h.active),
                "devices_total": len(hosts),
                "adapter": getattr(adapter, "name", ""),
            })
            if self._fail_streak >= 2:
                self.db.log_event("info", "ارتباط با مودم دوباره برقرار شد")
            self._fail_streak = 0
            self._auth_failures = 0
            self._blocked_until = 0
            self.status["blocked_until"] = 0
            self._maybe_cleanup(now)
            return True

        except RouterError as exc:
            self._fail_streak += 1
            self._set_error(exc.kind, str(exc))
            if exc.kind == "auth":
                self._auth_failures += 1
                wait = min(3600, 600 * (2 ** min(4, self._auth_failures - 1)))
                self._blocked_until = now + wait
                self._block_kind = "auth"
                self.status["blocked_until"] = self._blocked_until
                self.db.log_event(
                    "error",
                    f"ورود به مودم ناموفق بود؛ برای محافظت از قفل شدن، {wait // 60} دقیقه صبر می‌کنیم",
                )
            elif exc.kind == "locked":
                self._blocked_until = now + 300
                self._block_kind = "locked"
                self.status["blocked_until"] = self._blocked_until
                self.db.log_event("error", "مودم ورود را موقتاً قفل کرده است؛ ۵ دقیقه صبر می‌کنیم")
            elif exc.kind == "busy":
                self._blocked_until = now + 60
                self._block_kind = "busy"
                self.status["blocked_until"] = self._blocked_until
                self.db.log_event("warn", "یک نشست دیگر روی مودم باز است؛ ۱ دقیقه صبر می‌کنیم")
            if self._fail_streak in (1, 3, 10):
                self.db.log_event("error", f"poll failed ({exc.kind}): {exc}")
            if exc.kind in ("session", "auth", "locked", "busy", "network"):
                self.reset_adapter()
            return False
        except Exception as exc:  # unexpected
            self._fail_streak += 1
            self._set_error("internal", f"{exc.__class__.__name__}: {exc}")
            self.db.log_event("error", "poll error: " + traceback.format_exc(limit=2)[:400])
            self.reset_adapter()
            return False
        finally:
            self.status["polling"] = False
            self.status["fail_streak"] = self._fail_streak

    def _set_error(self, kind: str, message: str) -> None:
        self.status.update({
            "connected": False,
            "error": message,
            "error_kind": kind,
            "fail_streak": self._fail_streak,
        })

    # ---- WAN ---------------------------------------------------------
    def _poll_wan(self, adapter: RouterAdapter, now: int) -> dict[str, Any]:
        try:
            wan = adapter.fetch_wan()
        except RouterError:
            raise
        data = wan.as_dict()
        data["ts"] = now

        last = self.db.last_wan()
        today = day_str(now)
        if last:
            rx_delta = wan.total_rx - int(last.get("total_rx") or 0)
            tx_delta = wan.total_tx - int(last.get("total_tx") or 0)
            if rx_delta < 0:
                # WAN counter reset on reconnect: attribute the fresh part only.
                rx_delta = max(0, wan.total_rx)
            if tx_delta < 0:
                tx_delta = max(0, wan.total_tx)
            if 0 < rx_delta < MAX_SANE_DELTA and 0 < tx_delta < MAX_SANE_DELTA:
                self.db.add_wan_daily(today, rx_delta, tx_delta)
            elif rx_delta >= MAX_SANE_DELTA or tx_delta >= MAX_SANE_DELTA:
                self.db.log_event("warn", "پرش شمارنده‌ی مودم نادیده گرفته شد")
        self.db.add_wan_sample(data)
        return data

    # ---- per host ----------------------------------------------------
    def _poll_hosts(self, adapter: RouterAdapter, now: int) -> list[HostStat]:
        hosts = adapter.fetch_hosts()
        today = day_str(now)
        seen: set[str] = set()
        for host in hosts:
            mac = mac_norm(host.mac)
            if not mac:
                continue
            seen.add(mac)
            host.mac = mac
            is_self = bool(host.ip and host.ip in self._self_ips)
            device_id = self.db.upsert_device({
                "mac": mac,
                "ip": host.ip,
                "hostname": host.hostname,
                "vendor": vendor_for_mac(mac),
                "conn_type": host.conn_type,
                "ssid": host.ssid,
            }, now, is_self=is_self)

            prev = self.db.last_counters(device_id)
            if prev is not None and not host.counters:
                # Firmware without cumulative counters: integrate the live rate.
                _last_rx, _last_tx, last_ts = prev
                dt = max(0, min(now - last_ts, 300))
                if dt and (host.down_rate or host.up_rate):
                    self.db.add_usage(today, device_id,
                                      int(host.down_rate * dt), int(host.up_rate * dt))
                if now - last_ts >= 60:
                    self.db.add_host_sample(now, device_id, 0, 0,
                                            host.down_rate, host.up_rate,
                                            1 if host.active else 0)
                continue
            if prev is not None:
                last_rx, last_tx, last_ts = prev
                rx_delta = host.rx_bytes - last_rx
                tx_delta = host.tx_bytes - last_tx
                if rx_delta < 0:
                    # Router reboot / counter reset: only the new part is real.
                    rx_delta = max(0, host.rx_bytes)
                if tx_delta < 0:
                    tx_delta = max(0, host.tx_bytes)
                # A device that was offline for long may still hold cumulative
                # counters, so no time-based capping here; only sanity limits.
                if rx_delta < MAX_SANE_DELTA and tx_delta < MAX_SANE_DELTA:
                    self.db.add_usage(today, device_id, rx_delta, tx_delta)
                else:
                    self.db.log_event("warn", f"پرش شمارنده برای {mac} نادیده گرفته شد")
                # Hourly rollup lives in usage_daily; raw samples kept 3 days.
                if now - last_ts >= 60:
                    self.db.add_host_sample(now, device_id, host.rx_bytes, host.tx_bytes,
                                            host.down_rate, host.up_rate, 1 if host.active else 0)
            else:
                # First sighting: record the baseline, don't bill past traffic.
                self.db.add_host_sample(now, device_id, host.rx_bytes, host.tx_bytes,
                                        host.down_rate, host.up_rate, 1 if host.active else 0)

        cutoff = now - max(60, int(self.config.offline_after_min) * 60)
        if hosts:
            self.db.mark_offline(seen, cutoff)
        return hosts

    # ---- maintenance -------------------------------------------------
    def _maybe_cleanup(self, now: int) -> None:
        if now - self._last_cleanup < 3600:
            return
        self._last_cleanup = now
        try:
            self.db.cleanup()
        except Exception:
            pass

    # ---- read helpers for the API ------------------------------------
    def snapshot(self) -> dict[str, Any]:
        cfg = self.config
        today = day_str()
        month = billing_month_start(now_date(), cfg.reset_day).isoformat()
        devices = self.db.list_devices(today, month)
        wan_hist = self.db.wan_daily(120)
        month_total = sum(d["month_bytes"] for d in devices)
        all_time = sum(d["total_bytes"] for d in devices)
        return {
            "status": dict(self.status),
            "config": cfg.public(),
            "devices": devices,
            "wan_history": wan_hist,
            "totals": {
                "month_bytes": month_total,
                "today_bytes": sum(d["today_bytes"] for d in devices),
                "all_time_bytes": all_time,
                "wan_month_bytes": sum(r["rx"] + r["tx"] for r in wan_hist[-30:]),
            },
            "events": self.db.recent_events(20),
            "server_time": now_ts(),
        }


def now_date():
    import datetime as _dt
    return _dt.date.today()
