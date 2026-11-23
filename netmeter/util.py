"""Small helpers shared by the app."""
from __future__ import annotations

import datetime as _dt
import math
import re
import time
from typing import Optional

FA_DIGITS = str.maketrans("0123456789", "۰۱۲۳۴۵۶۷۸۹")


def now_ts() -> int:
    return int(time.time())


def local_now() -> _dt.datetime:
    return _dt.datetime.now()


def day_str(ts: Optional[float] = None) -> str:
    d = _dt.datetime.fromtimestamp(ts) if ts is not None else _dt.datetime.now()
    return d.strftime("%Y-%m-%d")


def month_start_str(ts: Optional[float] = None) -> str:
    d = _dt.datetime.fromtimestamp(ts) if ts is not None else _dt.datetime.now()
    return d.strftime("%Y-%m-01")


def human_bytes(n: float) -> str:
    n = float(n or 0)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n /= 1024.0
        i += 1
    if i == 0:
        return f"{int(n)} {units[i]}"
    return f"{n:.2f} {units[i]}"


def human_rate(bps: float) -> str:
    return human_bytes(bps) + "/s"


def to_fa(value) -> str:
    return str(value).translate(FA_DIGITS)


def mac_norm(value: str) -> str:
    """Normalize MAC to upper-case AA:BB:CC:DD:EE:FF."""
    if not value:
        return ""
    hexpart = re.sub(r"[^0-9A-Fa-f]", "", value)
    if len(hexpart) != 12:
        return value.strip().upper()
    return ":".join(hexpart[i:i + 2] for i in range(0, 12, 2)).upper()


def safe_int(value, default: int = 0) -> int:
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
            return default
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return default


def safe_float(value, default: float = 0.0) -> float:
    try:
        f = float(str(value).strip())
        return f if math.isfinite(f) else default
    except (TypeError, ValueError):
        return default


def parse_data_limit(text: str) -> int:
    """Parse '100GB', '1.5TB', '500MB', '123' into bytes."""
    if text is None:
        return 0
    s = str(text).strip().upper().replace(" ", "")
    if not s:
        return 0
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(TB|GB|MB|KB|B)?", s)
    if not m:
        return 0
    n = float(m.group(1))
    unit = m.group(2) or "B"
    mult = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3, "TB": 1024 ** 4}[unit]
    return int(n * mult)


def gregorian_to_jalali(gy: int, gm: int, gd: int) -> tuple[int, int, int]:
    """Gregorian date to Solar Hijri (Jalali)."""
    g_d_m = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    if gy > 1600:
        jy = 979
        gy -= 1600
    else:
        jy = 0
        gy -= 621
    gy2 = gy + 1 if gm > 2 else gy
    days = (365 * gy) + ((gy2 + 3) // 4) - ((gy2 + 99) // 100) + ((gy2 + 399) // 400) - 80 + gd + g_d_m[gm - 1]
    jy += 33 * (days // 12053)
    days %= 12053
    jy += 4 * (days // 1461)
    days %= 1461
    if days > 365:
        jy += (days - 1) // 365
        days = (days - 1) % 365
    if days < 186:
        jm = 1 + days // 31
        jd = 1 + days % 31
    else:
        jm = 7 + (days - 186) // 30
        jd = 1 + (days - 186) % 30
    return jy, jm, jd


JALALI_MONTHS = [
    "فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور",
    "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند",
]


def jalali_to_gregorian(jy: int, jm: int, jd: int) -> tuple[int, int, int]:
    """Solar Hijri date to Gregorian (mirrors the jalaali-js algorithm)."""
    jy += 1595
    days = -355668 + (365 * jy) + ((jy // 33) * 8) + (((jy % 33) + 3) // 4) + jd
    if jm < 7:
        days += (jm - 1) * 31
    else:
        days += ((jm - 7) * 30) + 186
    gy = 400 * (days // 146097)
    days %= 146097
    if days > 36524:
        days -= 1
        gy += 100 * (days // 36524)
        days %= 36524
        if days >= 365:
            days += 1
    gy += 4 * (days // 1461)
    days %= 1461
    if days > 365:
        gy += (days - 1) // 365
        days = (days - 1) % 365
    gd = days + 1
    leap = (gy % 4 == 0 and gy % 100 != 0) or (gy % 400 == 0)
    lengths = [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    gm = 1
    for length in lengths:
        if gd <= length:
            break
        gd -= length
        gm += 1
    return gy, gm, gd


def jalali_month_start(day: _dt.date) -> _dt.date:
    """Gregorian date of the 1st day of the Jalali month containing ``day``."""
    jy, jm, _ = gregorian_to_jalali(day.year, day.month, day.day)
    gy, gm, gd = jalali_to_gregorian(jy, jm, 1)
    return _dt.date(gy, gm, gd)


def jalali_str(ts: Optional[float] = None, with_year: bool = False) -> str:
    d = _dt.datetime.fromtimestamp(ts) if ts is not None else _dt.datetime.now()
    jy, jm, jd = gregorian_to_jalali(d.year, d.month, d.day)
    if with_year:
        return f"{jd} {JALALI_MONTHS[jm - 1]} {jy}"
    return f"{jd} {JALALI_MONTHS[jm - 1]}"


OUI_VENDORS = {
    "00:1A:11": "Google", "00:1B:63": "Apple", "00:1E:C2": "Apple",
    "00:25:00": "Apple", "3C:07:54": "Apple", "A4:83:E7": "Apple",
    "F0:18:98": "Apple", "DC:A6:32": "Raspberry Pi", "B8:27:EB": "Raspberry Pi",
    "E4:5F:01": "Raspberry Pi", "00:1E:58": "D-Link", "00:1C:F0": "D-Link",
    "F4:8E:38": "Dell", "00:1A:A0": "Dell", "00:1B:21": "Intel",
    "3C:97:0E": "Intel", "8C:16:45": "Intel", "A0:36:9F": "Intel",
    "00:0C:29": "VMware", "00:50:56": "VMware", "00:05:69": "VMware",
    "00:15:5D": "Microsoft", "28:CD:C1": "Samsung", "34:23:BA": "Samsung",
    "5C:0A:5B": "Samsung", "78:1D:BA": "Samsung", "8C:77:12": "Samsung",
    "B0:72:BF": "Samsung", "E8:50:8B": "Samsung", "00:9E:C8": "Xiaomi",
    "28:6C:07": "Xiaomi", "50:8F:4C": "Xiaomi", "64:B4:73": "Xiaomi",
    "78:11:DC": "Xiaomi", "8C:BE:BE": "Xiaomi", "A4:50:46": "Xiaomi",
    "C4:0B:CB": "Xiaomi", "F0:B4:29": "Xiaomi", "24:DF:6A": "Huawei",
    "48:46:FB": "Huawei", "5C:7D:5E": "Huawei", "70:72:3C": "Huawei",
    "88:53:D4": "Huawei", "C8:94:BB": "Huawei", "E0:24:7F": "Huawei",
    "00:1D:AA": "Huawei", "00:1E:10": "Huawei", "D8:43:AE": "Realtek",
    "00:E0:4C": "Realtek", "52:54:00": "QEMU", "00:16:3E": "Xen",
    "00:1A:79": "TP-Link", "14:CC:20": "TP-Link", "50:C7:BF": "TP-Link",
    "A4:2B:B0": "TP-Link", "C0:25:E9": "TP-Link", "F4:F2:6D": "TP-Link",
    "24:0A:C4": "Espressif", "24:6F:28": "Espressif", "30:AE:A4": "Espressif",
    "3C:71:BF": "Espressif", "84:F3:EB": "Espressif", "A4:CF:12": "Espressif",
    "AC:67:B2": "Espressif", "B4:E6:2D": "Espressif", "CC:50:E3": "Espressif",
    "DC:4F:22": "Espressif", "EC:FA:BC": "Espressif", "F4:CF:A2": "Espressif",
    "00:17:88": "Philips Hue", "EC:B5:FA": "Philips Hue",
    "00:04:4B": "NVIDIA", "48:B0:2D": "NVIDIA",
}


def vendor_for_mac(mac: str) -> str:
    m = mac_norm(mac)
    prefix = m[:8]
    return OUI_VENDORS.get(prefix, "")
