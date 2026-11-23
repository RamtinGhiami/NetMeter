"""Start NetMeter with Windows (HKCU Run key, no admin rights needed)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE_NAME = "NetMeter"


def _launch_command(data_dir: str | None = None) -> str:
    suffix = f' --data-dir "{data_dir}"' if data_dir else ""
    if getattr(sys, "frozen", False):
        exe = Path(sys.executable).resolve()
        return f'"{exe}" --no-browser{suffix}'
    pyw = Path(sys.executable).with_name("pythonw.exe")
    if not pyw.exists():
        pyw = Path(sys.executable)
    entry = Path(__file__).resolve().parent / "run.pyw"
    if entry.exists():
        return f'"{pyw}" "{entry}" --no-browser{suffix}'
    return f'"{pyw}" -m netmeter --no-browser{suffix}'


def apply_autostart(enabled: bool, data_dir: str | None = None) -> bool:
    if os.name != "nt":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0,
                            winreg.KEY_SET_VALUE) as key:
            if enabled:
                winreg.SetValueEx(key, VALUE_NAME, 0, winreg.REG_SZ,
                                  _launch_command(data_dir))
            else:
                try:
                    winreg.DeleteValue(key, VALUE_NAME)
                except FileNotFoundError:
                    pass
        return True
    except Exception:
        return False


def is_enabled() -> bool:
    if os.name != "nt":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, VALUE_NAME)
            return bool(value)
    except Exception:
        return False
