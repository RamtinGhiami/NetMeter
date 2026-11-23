"""Demo data for previewing the dashboard without a router (dev only)."""
from __future__ import annotations

import datetime as _dt
import random
import time

from .db import Database


DEVICES = [
    {"mac": "A4:83:E7:11:22:33", "ip": "192.168.70.109", "hostname": "Laptop-Mahdi",
     "vendor": "Apple", "conn_type": "wifi", "ssid": "Home-5G", "self": True,
     "weight": 0.45, "custom_name": "لپ‌تاپ مهدی", "category": "laptop"},
    {"mac": "78:1D:BA:AA:BB:CC", "ip": "192.168.70.101", "hostname": "Samsung-TV",
     "vendor": "Samsung", "conn_type": "wifi", "ssid": "Home-5G", "self": False,
     "weight": 0.30, "custom_name": "تلویزیون سالن", "category": "tv"},
    {"mac": "50:8F:4C:12:34:56", "ip": "192.168.70.112", "hostname": "Redmi-Note-13",
     "vendor": "Xiaomi", "conn_type": "wifi", "ssid": "Home-5G", "self": False,
     "weight": 0.18, "custom_name": "گوشی رضا", "category": "phone"},
    {"mac": "24:0A:C4:99:88:77", "ip": "192.168.70.120", "hostname": "ESP32-Lamp",
     "vendor": "Espressif", "conn_type": "wifi", "ssid": "Home-IoT", "self": False,
     "weight": 0.02, "custom_name": "لامپ هوشمند", "category": "iot"},
    {"mac": "24:DF:6A:44:55:66", "ip": "192.168.70.130", "hostname": "PS5-Salon",
     "vendor": "Huawei", "conn_type": "lan", "ssid": "", "self": False,
     "weight": 0.05, "custom_name": "", "category": "console"},
]


def seed(db: Database, days: int = 60) -> None:
    rng = random.Random(20261123)
    now = int(time.time())
    ids: list[int] = []
    for dev in DEVICES:
        device_id = db.upsert_device({
            "mac": dev["mac"], "ip": dev["ip"], "hostname": dev["hostname"],
            "vendor": dev["vendor"], "conn_type": dev["conn_type"], "ssid": dev["ssid"],
        }, now, is_self=dev["self"])
        ids.append(device_id)
        if dev.get("custom_name") or dev.get("category"):
            db.set_device_meta(dev["mac"], dev.get("custom_name", ""), dev.get("category", ""))

    today = _dt.date.today()
    for back in range(days, -1, -1):
        day = today - _dt.timedelta(days=back)
        # A believable pattern: heavier on weekends and evenings, with noise.
        weekend = 1.6 if day.weekday() in (3, 4) else 1.0
        base_gb = (1.1 + rng.random() * 2.4) * weekend
        for dev, device_id in zip(DEVICES, ids):
            share = dev["weight"] * (0.6 + rng.random() * 0.8)
            total = int(base_gb * share * 1024 ** 3)
            rx = int(total * (0.72 + rng.random() * 0.18))
            db.add_usage(day.isoformat(), device_id, rx, max(0, total - rx))

    # WAN daily slightly above the sum of devices (guest traffic, router itself).
    for back in range(days, -1, -1):
        day = today - _dt.timedelta(days=back)
        rows = db.query(
            "SELECT SUM(rx_bytes) rx, SUM(tx_bytes) tx FROM usage_daily WHERE day=?",
            (day.isoformat(),),
        )
        row = rows[0] if rows else None
        if row and (row["rx"] or 0) > 0:
            db.add_wan_daily(day.isoformat(), int((row["rx"] or 0) * 1.07),
                             int((row["tx"] or 0) * 1.05))

    # A couple of live samples so rates render.
    for dev, device_id in zip(DEVICES, ids):
        db.add_host_sample(now, device_id, 42 * 1024 ** 3, 3 * 1024 ** 3,
                           rng.randint(0, 9_000_000) if dev["self"] else rng.randint(0, 2_000_000),
                           rng.randint(0, 400_000), 1)

    db.log_event("info", "حالت نمایشی فعال شد — داده‌ها نمونه هستند")
    db.log_event("info", "ارتباط با مودم برقرار شد")
    db.log_event("warn", "دستگاه ESP32-Lamp برای ۷ دقیقه آفلاین بود")


def demo_status() -> dict:
    now = int(time.time())
    return {
        "running": True,
        "polling": False,
        "connected": True,
        "last_poll": now,
        "last_ok": now - 3,
        "error": "",
        "error_kind": "",
        "next_poll": now + 7,
        "poll_count": 1042,
        "fail_streak": 0,
        "wan": {
            "total_rx": 812 * 1024 ** 3, "total_tx": 96 * 1024 ** 3,
            "month_rx": 143 * 1024 ** 3, "month_tx": 17 * 1024 ** 3,
            "day_used": 6 * 1024 ** 3, "down_rate": 5_400_000,
            "up_rate": 720_000, "month_clear": "2026-11-01",
            "quota_bytes": 0, "reset_day": 0,
        },
        "router": {
            "model": "H155-383", "firmware": "11.0.3.1(H100SP1C00)",
            "network_type": "5G NSA", "signal": "5 (RSRP -78 dBm)",
            "operator": "MCI", "wan_ip": "10.44.12.87", "uptime": 390_000,
        },
        "devices_online": 4,
        "devices_total": 5,
        "adapter": "huawei",
    }
