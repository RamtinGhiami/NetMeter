"""SQLite storage for devices, raw samples and daily aggregates."""
from __future__ import annotations

import csv
import datetime as _dt
import io
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS devices (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    mac         TEXT UNIQUE NOT NULL,
    ip          TEXT NOT NULL DEFAULT '',
    hostname    TEXT NOT NULL DEFAULT '',
    custom_name TEXT NOT NULL DEFAULT '',
    category    TEXT NOT NULL DEFAULT '',
    vendor      TEXT NOT NULL DEFAULT '',
    conn_type   TEXT NOT NULL DEFAULT '',
    ssid        TEXT NOT NULL DEFAULT '',
    first_seen  INTEGER NOT NULL,
    last_seen   INTEGER NOT NULL,
    online      INTEGER NOT NULL DEFAULT 0,
    is_self     INTEGER NOT NULL DEFAULT 0,
    last_rx     INTEGER,
    last_tx     INTEGER,
    last_ts     INTEGER
);

CREATE TABLE IF NOT EXISTS usage_daily (
    day       TEXT NOT NULL,
    device_id INTEGER NOT NULL,
    rx_bytes  INTEGER NOT NULL DEFAULT 0,
    tx_bytes  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, device_id)
);
CREATE INDEX IF NOT EXISTS idx_usage_device_day ON usage_daily(device_id, day);

CREATE TABLE IF NOT EXISTS host_samples (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        INTEGER NOT NULL,
    device_id INTEGER NOT NULL,
    rx_total  INTEGER NOT NULL DEFAULT 0,
    tx_total  INTEGER NOT NULL DEFAULT 0,
    down_rate INTEGER NOT NULL DEFAULT 0,
    up_rate   INTEGER NOT NULL DEFAULT 0,
    online    INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_host_samples_device_ts ON host_samples(device_id, ts);

CREATE TABLE IF NOT EXISTS wan_samples (
    ts         INTEGER PRIMARY KEY,
    total_rx   INTEGER NOT NULL DEFAULT 0,
    total_tx   INTEGER NOT NULL DEFAULT 0,
    month_rx   INTEGER NOT NULL DEFAULT 0,
    month_tx   INTEGER NOT NULL DEFAULT 0,
    day_used   INTEGER NOT NULL DEFAULT 0,
    down_rate  INTEGER NOT NULL DEFAULT 0,
    up_rate    INTEGER NOT NULL DEFAULT 0,
    month_clear TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS wan_daily (
    day      TEXT PRIMARY KEY,
    rx_bytes INTEGER NOT NULL DEFAULT 0,
    tx_bytes INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      INTEGER NOT NULL,
    level   TEXT NOT NULL DEFAULT 'info',
    message TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);
"""


def billing_month_start(day: _dt.date, reset_day: int) -> _dt.date:
    """Start of the usage period.

    ``reset_day == 0`` means the Jalali (Solar Hijri) calendar month, which is
    what "این ماه" usually means for Iranian users. A value of 1..31 selects
    that day of the Gregorian month.
    """
    if reset_day <= 0:
        from .util import jalali_month_start
        return jalali_month_start(day)
    if day.day >= reset_day:
        return day.replace(day=reset_day)
    year, month = day.year, day.month - 1
    if month == 0:
        year -= 1
        month = 12
    return _dt.date(year, month, min(reset_day, _days_in_month(year, month)))


def _days_in_month(year: int, month: int) -> int:
    if month == 12:
        return 31
    return (_dt.date(year, month + 1, 1) - _dt.timedelta(days=1)).day


class Database:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self.conn = sqlite3.connect(str(self.path), check_same_thread=False, timeout=30)
        self.conn.row_factory = sqlite3.Row
        with self._lock:
            self.conn.executescript(SCHEMA)
            self._migrate()
            self.conn.commit()

    def _migrate(self) -> None:
        """Add columns that older databases don't have (very light migration)."""
        cols = {r["name"] for r in self.conn.execute("PRAGMA table_info(devices)")}
        for name in ("custom_name", "category"):
            if name not in cols:
                self.conn.execute(
                    f"ALTER TABLE devices ADD COLUMN {name} TEXT NOT NULL DEFAULT ''"
                )

    def close(self) -> None:
        with self._lock:
            try:
                self.conn.close()
            except Exception:
                pass

    # ------------------------------------------------------------------
    def execute(self, sql: str, params: Iterable[Any] = ()) -> sqlite3.Cursor:
        with self._lock:
            cur = self.conn.execute(sql, tuple(params))
            self.conn.commit()
            return cur

    def query(self, sql: str, params: Iterable[Any] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return list(self.conn.execute(sql, tuple(params)).fetchall())

    def query_one(self, sql: str, params: Iterable[Any] = ()) -> Optional[sqlite3.Row]:
        with self._lock:
            return self.conn.execute(sql, tuple(params)).fetchone()

    # ---- meta --------------------------------------------------------
    def get_meta(self, key: str, default: str = "") -> str:
        row = self.query_one("SELECT value FROM meta WHERE key=?", (key,))
        return row["value"] if row else default

    def set_meta(self, key: str, value: str) -> None:
        self.execute(
            "INSERT INTO meta(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )

    # ---- events ------------------------------------------------------
    def log_event(self, level: str, message: str) -> None:
        self.execute(
            "INSERT INTO events(ts,level,message) VALUES(?,?,?)",
            (int(time.time()), level, message[:500]),
        )

    def recent_events(self, limit: int = 30) -> list[dict[str, Any]]:
        rows = self.query("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))
        return [dict(r) for r in rows]

    # ---- devices -----------------------------------------------------
    def upsert_device(self, host: dict[str, Any], now: int, is_self: bool = False) -> int:
        mac = host["mac"]
        row = self.query_one("SELECT * FROM devices WHERE mac=?", (mac,))
        vendor = host.get("vendor") or ""
        hostname = (host.get("hostname") or "").strip()
        if row is None:
            cur = self.execute(
                "INSERT INTO devices(mac,ip,hostname,vendor,conn_type,ssid,first_seen,last_seen,online,is_self) "
                "VALUES(?,?,?,?,?,?,?,?,?,?)",
                (mac, host.get("ip", ""), hostname, vendor, host.get("conn_type", ""),
                 host.get("ssid", ""), now, now, 1, 1 if is_self else 0),
            )
            return int(cur.lastrowid)
        updates = {
            "ip": host.get("ip") or row["ip"],
            "hostname": hostname or row["hostname"],
            "vendor": vendor or row["vendor"],
            "conn_type": host.get("conn_type") or row["conn_type"],
            "ssid": host.get("ssid") or row["ssid"],
            "last_seen": now,
            "online": 1,
        }
        if is_self:
            updates["is_self"] = 1
        sets = ", ".join(f"{k}=?" for k in updates)
        self.execute(f"UPDATE devices SET {sets} WHERE id=?", (*updates.values(), row["id"]))
        return int(row["id"])

    def touch_device(self, mac: str, now: int, online: int = 1) -> None:
        self.execute("UPDATE devices SET last_seen=?, online=? WHERE mac=?", (now, online, mac))

    def last_counters(self, device_id: int) -> Optional[tuple[int, int, int]]:
        row = self.query_one(
            "SELECT rx_total, tx_total, ts FROM host_samples WHERE device_id=? ORDER BY ts DESC LIMIT 1",
            (device_id,),
        )
        if not row:
            return None
        return int(row["rx_total"]), int(row["tx_total"]), int(row["ts"])

    def add_host_sample(self, ts: int, device_id: int, rx: int, tx: int,
                        down_rate: int, up_rate: int, online: int = 1) -> None:
        self.execute(
            "INSERT INTO host_samples(ts,device_id,rx_total,tx_total,down_rate,up_rate,online) "
            "VALUES(?,?,?,?,?,?,?)",
            (ts, device_id, rx, tx, down_rate, up_rate, online),
        )
        self.execute(
            "UPDATE devices SET last_rx=?, last_tx=?, last_ts=? WHERE id=?",
            (rx, tx, ts, device_id),
        )

    def add_usage(self, day: str, device_id: int, rx_delta: int, tx_delta: int) -> None:
        if rx_delta <= 0 and tx_delta <= 0:
            return
        self.execute(
            "INSERT INTO usage_daily(day,device_id,rx_bytes,tx_bytes) VALUES(?,?,?,?) "
            "ON CONFLICT(day,device_id) DO UPDATE SET "
            "rx_bytes=rx_bytes+excluded.rx_bytes, tx_bytes=tx_bytes+excluded.tx_bytes",
            (day, device_id, max(0, rx_delta), max(0, tx_delta)),
        )

    def mark_offline(self, seen_macs: set[str], cutoff: int) -> None:
        if not seen_macs:
            self.execute("UPDATE devices SET online=0 WHERE last_seen < ?", (cutoff,))
            return
        placeholders = ",".join("?" for _ in seen_macs)
        self.execute(
            f"UPDATE devices SET online=0 WHERE last_seen < ? AND mac NOT IN ({placeholders})",
            (cutoff, *seen_macs),
        )

    def list_devices(self, today: str, month_start: str) -> list[dict[str, Any]]:
        rows = self.query(
            """
            SELECT d.*,
              CASE WHEN d.custom_name<>'' THEN d.custom_name ELSE d.hostname END AS display_name,
              COALESCE((SELECT u.rx_bytes+u.tx_bytes FROM usage_daily u
                        WHERE u.device_id=d.id AND u.day=?),0) AS today_bytes,
              COALESCE((SELECT SUM(u.rx_bytes+u.tx_bytes) FROM usage_daily u
                        WHERE u.device_id=d.id AND u.day>=?),0) AS month_bytes,
              COALESCE((SELECT SUM(u.rx_bytes+u.tx_bytes) FROM usage_daily u
                        WHERE u.device_id=d.id),0) AS total_bytes,
              COALESCE((SELECT s.down_rate FROM host_samples s
                        WHERE s.device_id=d.id ORDER BY s.ts DESC LIMIT 1),0) * d.online AS down_rate,
              COALESCE((SELECT s.up_rate FROM host_samples s
                        WHERE s.device_id=d.id ORDER BY s.ts DESC LIMIT 1),0) * d.online AS up_rate
            FROM devices d
            ORDER BY d.online DESC, today_bytes DESC,
                     COALESCE(NULLIF(d.custom_name,''), d.hostname) COLLATE NOCASE
            """,
            (today, month_start),
        )
        out = []
        for r in rows:
            d = dict(r)
            d["mac"] = d["mac"]
            d["online"] = bool(d["online"])
            d["is_self"] = bool(d["is_self"])
            out.append(d)
        return out

    def device_by_mac(self, mac: str) -> Optional[dict[str, Any]]:
        row = self.query_one("SELECT * FROM devices WHERE mac=?", (mac,))
        return dict(row) if row else None

    def set_device_meta(self, mac: str, name: Optional[str] = None,
                        category: Optional[str] = None) -> Optional[dict[str, Any]]:
        """Save the user-chosen name / category. Empty string resets to default."""
        row = self.query_one("SELECT id FROM devices WHERE mac=?", (mac,))
        if row is None:
            return None
        updates: dict[str, str] = {}
        if name is not None:
            updates["custom_name"] = name.strip()[:64]
        if category is not None:
            updates["category"] = category.strip()[:24]
        if updates:
            sets = ", ".join(f"{k}=?" for k in updates)
            self.execute(f"UPDATE devices SET {sets} WHERE mac=?", (*updates.values(), mac))
        dev = self.device_by_mac(mac)
        if dev is not None:
            dev["display_name"] = dev.get("custom_name") or dev.get("hostname") or ""
        return dev

    def device_history(self, mac: str, days: int = 30) -> list[dict[str, Any]]:
        row = self.query_one("SELECT id FROM devices WHERE mac=?", (mac,))
        if not row:
            return []
        end = _dt.date.today()
        start = end - _dt.timedelta(days=max(1, days) - 1)
        rows = self.query(
            "SELECT day, rx_bytes, tx_bytes FROM usage_daily WHERE device_id=? AND day>=? ORDER BY day",
            (row["id"], start.isoformat()),
        )
        by_day = {r["day"]: (int(r["rx_bytes"]), int(r["tx_bytes"])) for r in rows}
        out = []
        for i in range(max(1, days)):
            d = start + _dt.timedelta(days=i)
            key = d.isoformat()
            rx, tx = by_day.get(key, (0, 0))
            out.append({"day": key, "rx": rx, "tx": tx})
        return out

    # ---- WAN ---------------------------------------------------------
    def last_wan(self) -> Optional[dict[str, Any]]:
        row = self.query_one("SELECT * FROM wan_samples ORDER BY ts DESC LIMIT 1")
        return dict(row) if row else None

    def add_wan_sample(self, data: dict[str, Any]) -> None:
        self.execute(
            "INSERT OR REPLACE INTO wan_samples"
            "(ts,total_rx,total_tx,month_rx,month_tx,day_used,down_rate,up_rate,month_clear) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (data["ts"], data.get("total_rx", 0), data.get("total_tx", 0),
             data.get("month_rx", 0), data.get("month_tx", 0),
             data.get("day_used", 0), data.get("down_rate", 0),
             data.get("up_rate", 0), data.get("month_clear", "")),
        )

    def add_wan_daily(self, day: str, rx_delta: int, tx_delta: int) -> None:
        if rx_delta <= 0 and tx_delta <= 0:
            return
        self.execute(
            "INSERT INTO wan_daily(day,rx_bytes,tx_bytes) VALUES(?,?,?) "
            "ON CONFLICT(day) DO UPDATE SET rx_bytes=rx_bytes+excluded.rx_bytes, "
            "tx_bytes=tx_bytes+excluded.tx_bytes",
            (day, max(0, rx_delta), max(0, tx_delta)),
        )

    def wan_daily(self, days: int = 30) -> list[dict[str, Any]]:
        end = _dt.date.today()
        start = end - _dt.timedelta(days=max(1, days) - 1)
        rows = self.query("SELECT * FROM wan_daily WHERE day>=? ORDER BY day", (start.isoformat(),))
        by_day = {r["day"]: (int(r["rx_bytes"]), int(r["tx_bytes"])) for r in rows}
        out = []
        for i in range(max(1, days)):
            d = start + _dt.timedelta(days=i)
            rx, tx = by_day.get(d.isoformat(), (0, 0))
            out.append({"day": d.isoformat(), "rx": rx, "tx": tx})
        return out

    def wan_samples(self, hours: int = 6) -> list[dict[str, Any]]:
        cutoff = int(time.time()) - max(1, hours) * 3600
        rows = self.query(
            "SELECT ts,down_rate,up_rate,day_used FROM wan_samples WHERE ts>=? ORDER BY ts",
            (cutoff,),
        )
        return [dict(r) for r in rows]

    # ---- maintenance -------------------------------------------------
    def cleanup(self) -> None:
        now = int(time.time())
        self.execute("DELETE FROM host_samples WHERE ts < ?", (now - 3 * 86400,))
        self.execute("DELETE FROM wan_samples WHERE ts < ?", (now - 7 * 86400,))
        self.execute("DELETE FROM events WHERE ts < ?", (now - 30 * 86400,))

    def clear_all(self) -> None:
        with self._lock:
            self.conn.executescript(
                "DELETE FROM usage_daily; DELETE FROM host_samples; DELETE FROM wan_samples; "
                "DELETE FROM wan_daily; DELETE FROM events; "
                "UPDATE devices SET last_rx=NULL,last_tx=NULL,last_ts=NULL;"
            )
            self.conn.commit()

    # ---- exports -----------------------------------------------------
    def export_devices_csv(self, today: str, month_start: str) -> str:
        devices = self.list_devices(today, month_start)
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["MAC", "Name", "Category", "IP", "Hostname", "Vendor", "Type", "Online",
                    "TodayBytes", "MonthBytes", "TotalBytes", "DownBps", "UpBps", "LastSeen"])
        for d in devices:
            w.writerow([d["mac"], d.get("display_name") or d["hostname"],
                        d.get("category") or "", d["ip"], d["hostname"], d["vendor"],
                        d["conn_type"], 1 if d["online"] else 0, d["today_bytes"],
                        d["month_bytes"], d["total_bytes"], d["down_rate"], d["up_rate"],
                        d["last_seen"]])
        return buf.getvalue()

    def export_wan_csv(self, days: int = 90) -> str:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["Day", "DownloadBytes", "UploadBytes", "TotalBytes"])
        for row in self.wan_daily(days):
            w.writerow([row["day"], row["rx"], row["tx"], row["rx"] + row["tx"]])
        return buf.getvalue()
