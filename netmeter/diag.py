"""Local diagnostic: check the router connection without guessing in chat.

Run from the project folder:

    python -m netmeter.diag

The password is read with getpass (never echoed) and is only used for that
single connection test — nothing is saved unless you ask for it.
"""
from __future__ import annotations

import getpass
import json
import sys
import time
from typing import Any

from .config import Config, detect_gateway, default_data_dir
from .routers import build_adapter
from .routers.base import RouterError
from .util import human_bytes

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
DIM = "\033[2m"
RESET = "\033[0m"


def _ok(msg: str) -> None:
    print(f"{GREEN}✓{RESET} {msg}")


def _bad(msg: str) -> None:
    print(f"{RED}✗{RESET} {msg}")


def _warn(msg: str) -> None:
    print(f"{YELLOW}!{RESET} {msg}")


def _mask(value: str) -> str:
    value = str(value or "")
    if len(value) <= 4:
        return "*" * len(value)
    return value[:2] + "*" * max(3, len(value) - 4) + value[-2:]


def _mask_ip(ip: str) -> str:
    parts = str(ip or "").split(".")
    if len(parts) == 4:
        return ".".join(parts[:3] + ["*"])
    return _mask(ip)


def _show_hosts(hosts, limit: int = 6) -> None:
    print(f"\n{DIM}دستگاه‌های دیده‌شده ({len(hosts)} مورد):{RESET}")
    for h in hosts[:limit]:
        print(
            f"  • {_mask(h.mac)}  {_mask_ip(h.ip):<15}  "
            f"{h.hostname or '(بی‌نام)'}  "
            f"↓{human_bytes(h.rx_bytes)} ↑{human_bytes(h.tx_bytes)}"
        )
    if len(hosts) > limit:
        print(f"  … و {len(hosts) - limit} دستگاه دیگر")


def main() -> int:
    cfg = Config(default_data_dir())
    gateway = detect_gateway()

    print("=" * 58)
    print(" اینترنت‌متر — تست اتصال به مودم")
    print("=" * 58)
    print(f"پوشه‌ی داده: {cfg.data_dir}")
    if gateway:
        print(f"درگاه شبکه: {gateway}")
    if cfg.router_url:
        print(f"آدرس ذخیره‌شده: {cfg.router_url}")
    if cfg.password:
        print("رمز ذخیره‌شده: بله (رمزگشایی با حساب ویندوز)")
    else:
        print("رمز ذخیره‌شده: خیر")

    default_url = cfg.router_url or (f"https://{gateway}" if gateway else "")
    url = input(f"\nآدرس مودم [{default_url}]: ").strip() or default_url
    if not url:
        _bad("آدرس مودم خالی است.")
        return 2
    user = input(f"نام کاربری [{cfg.username or 'admin'}]: ").strip() or (cfg.username or "admin")

    if cfg.password and url == cfg.router_url and user == cfg.username:
        use_saved = input("از رمز ذخیره‌شده استفاده شود؟ [Y/n]: ").strip().lower()
        if use_saved not in ("n", "no"):
            password = cfg.password
        else:
            password = getpass.getpass("رمز عبور مودم (نمایش داده نمی‌شود): ")
    else:
        password = getpass.getpass("رمز عبور مودم (نمایش داده نمی‌شود): ")

    if not password:
        _bad("رمزی وارد نشد.")
        return 2

    _warn("هر تلاش ورود اشتباه یک فرصت از مودم کم می‌کند. اگر مطمئن نیستید، اول رمز را در پنل مودم تست کنید.")

    adapter = build_adapter(url, user, password, timeout=15)
    if adapter is None:
        _bad("آداپتر مناسبی برای این آدرس پیدا نشد.")
        return 2

    t0 = time.time()
    try:
        _ok("در حال اتصال…")
        adapter.initialize()
        _ok(f"صفحه‌ی مودم باز شد ({time.time() - t0:.1f} ثانیه)")
        st = adapter.state()
        print(f"  وضعیت نشست: State={st.get('State')} · account={st.get('accounts_number')} "
              f"· remain={st.get('remainwaittime')}")
        adapter.login(force=True)
        _ok("ورود موفق")
    except RouterError as exc:
        _bad(f"ورود ناموفق [{exc.kind}] {exc}")
        if exc.kind == "auth":
            print("\nراهنما:")
            print("  • نام کاربری پیش‌فرض بیشتر مودم‌های Huawei «admin» است، اما بعضی اپراتورها")
            print("    حساب دومی با نام دیگر می‌سازند؛ همان نامی را بزنید که در صفحه‌ی ورود مودم هست.")
            print("  • اگر چند بار پشت‌سرهم تلاش کنید، مودم موقتاً قفل می‌کند (۱ تا ۵ دقیقه).")
        elif exc.kind == "network":
            print("\nراهنما: آدرس https و درگاه شبکه را بررسی کنید؛ VPN/پروکسی سیستم را موقتاً خاموش کنید.")
        return 1
    except Exception as exc:  # pragma: no cover
        _bad(f"خطای غیرمنتظره: {exc.__class__.__name__}: {exc}")
        return 1

    try:
        hosts = adapter.fetch_hosts()
        if hosts:
            _ok(f"{len(hosts)} دستگاه با آمار ترافیک خوانده شد")
            _show_hosts(hosts)
            sample = hosts[0].raw
            print(f"\n{DIM}فیلدهای خام نخستین دستگاه:{RESET}")
            for key in sorted(sample.keys()):
                value = sample[key]
                if key.lower() in ("macaddress", "ipaddress", "hostname", "actualname"):
                    value = _mask(str(value))
                print(f"  {key} = {value}")
        else:
            _bad("هیچ دستگاهی برنگشت — احتمالاً این حساب اجازه‌ی خواندن HostInfo را ندارد.")

        wan = adapter.fetch_wan()
        _ok("آمار کل مودم خوانده شد")
        print(f"  ماه: ↓{human_bytes(wan.month_rx)} ↑{human_bytes(wan.month_tx)}")
        print(f"  امروز: {human_bytes(wan.day_used)}")
        info = adapter.fetch_info()
        print(f"  مدل: {info.model} · فرم‌ور: {info.firmware or '—'} · شبکه: {info.network_type or '—'}")
    except RouterError as exc:
        _bad(f"خواندن آمار ناموفق [{exc.kind}] {exc}")
        return 1

    print()
    save = input("این تنظیمات در برنامه ذخیره شود؟ [y/N]: ").strip().lower()
    if save in ("y", "yes", "بله"):
        cfg.router_url = url
        cfg.username = user
        cfg.set_password(password)
        cfg.save()
        _ok(f"ذخیره شد در {cfg.path}")
    else:
        print("ذخیره نشد.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
