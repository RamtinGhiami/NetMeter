"""Router adapter interfaces."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


class RouterError(Exception):
    """An error returned by the router or the transport layer."""

    def __init__(self, code: str, message: str = "", kind: str = "error"):
        super().__init__(message or code)
        self.code = str(code)
        self.kind = kind
        self.message = message

    def __str__(self) -> str:
        return self.message or f"router error {self.code}"


AUTH_CODES = {"108001", "108002", "108006"}
LOCK_CODES = {"108007", "108010"}
BUSY_CODES = {"108003", "108005", "108009"}
SESSION_CODES = {"100002", "125001", "125002", "125003"}
FORBIDDEN_CODES = {"100003"}


def classify(code: str) -> str:
    if code in AUTH_CODES:
        return "auth"
    if code in LOCK_CODES:
        return "locked"
    if code in BUSY_CODES:
        return "busy"
    if code in SESSION_CODES:
        return "session"
    if code in FORBIDDEN_CODES:
        return "forbidden"
    return "error"


@dataclass
class HostStat:
    mac: str
    ip: str = ""
    hostname: str = ""
    conn_type: str = ""
    ssid: str = ""
    rx_bytes: int = 0
    tx_bytes: int = 0
    down_rate: int = 0
    up_rate: int = 0
    active: bool = True
    counters: bool = True
    raw: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "mac": self.mac, "ip": self.ip, "hostname": self.hostname,
            "conn_type": self.conn_type, "ssid": self.ssid,
            "rx_bytes": self.rx_bytes, "tx_bytes": self.tx_bytes,
            "down_rate": self.down_rate, "up_rate": self.up_rate,
            "active": self.active,
        }


@dataclass
class WanStat:
    total_rx: int = 0
    total_tx: int = 0
    month_rx: int = 0
    month_tx: int = 0
    day_used: int = 0
    down_rate: int = 0
    up_rate: int = 0
    month_clear: str = ""
    quota_bytes: int = 0
    reset_day: int = 0
    raw: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "total_rx": self.total_rx, "total_tx": self.total_tx,
            "month_rx": self.month_rx, "month_tx": self.month_tx,
            "day_used": self.day_used, "down_rate": self.down_rate,
            "up_rate": self.up_rate, "month_clear": self.month_clear,
            "quota_bytes": self.quota_bytes, "reset_day": self.reset_day,
        }


@dataclass
class RouterInfo:
    model: str = ""
    firmware: str = ""
    network_type: str = ""
    signal: str = ""
    operator: str = ""
    wan_ip: str = ""
    uptime: int = 0
    raw: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "model": self.model, "firmware": self.firmware,
            "network_type": self.network_type, "signal": self.signal,
            "operator": self.operator, "wan_ip": self.wan_ip,
            "uptime": self.uptime,
        }


class RouterAdapter:
    name = "generic"

    def login(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def fetch_hosts(self) -> list[HostStat]:  # pragma: no cover - interface
        raise NotImplementedError

    def fetch_wan(self) -> WanStat:  # pragma: no cover - interface
        raise NotImplementedError

    def fetch_info(self) -> RouterInfo:  # pragma: no cover - interface
        raise NotImplementedError
