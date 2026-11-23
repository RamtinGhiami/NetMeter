"""Router adapter factory."""
from __future__ import annotations

from typing import Optional

from .base import HostStat, RouterAdapter, RouterError, RouterInfo, WanStat
from .huawei import HuaweiCPE

__all__ = [
    "HostStat", "RouterAdapter", "RouterError", "RouterInfo", "WanStat",
    "HuaweiCPE", "build_adapter",
]


def build_adapter(base_url: str, username: str, password: str,
                  timeout: int = 10) -> Optional[RouterAdapter]:
    """Return the best adapter for the given router URL.

    Huawei HiLink is the only fully implemented vendor right now; the factory
    exists so TP-Link/OpenWrt/SNMP adapters can be added without touching the
    collector.
    """
    if not base_url:
        return None
    return HuaweiCPE(base_url, username, password, timeout=timeout)
