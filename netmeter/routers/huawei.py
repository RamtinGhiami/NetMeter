"""Huawei HiLink / 5G CPE adapter.

The login is Huawei's SCRAM variant (challenge_login / authentication_login).
The logic is a Python port of the public CPE-Monitor project's router.rs
(GPL-2.0-or-later) and follows the WebUI contract of Huawei H155/H153/H165
firmware. Per-device counters come from ``system/HostInfo``.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import time
import xml.etree.ElementTree as ET
from collections import deque
from typing import Any, Optional

import requests
import urllib3

from ..util import mac_norm, parse_data_limit, safe_int, to_fa, vendor_for_mac
from .base import HostStat, RouterAdapter, RouterError, RouterInfo, WanStat, classify

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

XML_DECL = '<?xml version="1.0" encoding="UTF-8"?>'


def _xml_escape(value: Any) -> str:
    s = str(value)
    return (s.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _hmac(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def _pbkdf2(password: str, salt_hex: str, rounds: int) -> bytes:
    try:
        salt = bytes.fromhex(salt_hex)
    except ValueError:
        salt = salt_hex.encode("utf-8")
    if not (1 <= int(rounds) <= 2_000_000):
        raise RouterError("login", "پارامترهای ورود مودم نامعتبر است", "auth")
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(rounds), 32)


def _first(d: dict[str, Any], *keys: str) -> Any:
    for k in keys:
        if k in d and d[k] not in (None, ""):
            return d[k]
    # case-insensitive fallback
    low = {str(k).lower(): v for k, v in d.items()}
    for k in keys:
        v = low.get(k.lower())
        if v not in (None, ""):
            return v
    return None


def _truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in ("1", "true", "yes", "on", "online", "active")


def _as_list(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    if isinstance(value, dict):
        if any(str(k).lower() == "macaddress" for k in value.keys()):
            return [value]
        out = []
        for v in value.values():
            if isinstance(v, dict):
                out.append(v)
            elif isinstance(v, list):
                out.extend(x for x in v if isinstance(x, dict))
        return out
    return []


class HuaweiCPE(RouterAdapter):
    name = "huawei"

    def __init__(self, base_url: str, username: str, password: str, timeout: int = 10):
        self.base = base_url.rstrip("/")
        self.username = username or "admin"
        self.password = password or ""
        self.timeout = timeout
        self.session = requests.Session()
        self.session.trust_env = False          # never route LAN via FlClash/proxy
        self.session.verify = False
        self.session.headers.update({
            "User-Agent": "NetMeter/0.1 (Windows)",
            "Accept": "application/json, text/javascript, */*; q=0.01",
        })
        self.tokens: deque[str] = deque()
        self._logged_in = False
        self.info_cache: RouterInfo = RouterInfo()

    # ---- low level ---------------------------------------------------
    def _origin(self) -> str:
        return self.base

    def initialize(self) -> None:
        r = self.session.get(self.base + "/", timeout=self.timeout, verify=False,
                             allow_redirects=True)
        if r.url and r.url.rstrip("/") != self.base:
            m = re.match(r"^(https?://[^/]+)", r.url)
            if m:
                self.base = m.group(1).rstrip("/")
        self.tokens.clear()
        html = r.text or ""
        for m in re.finditer(r'name="csrf_token"\s+content="([^"]+)"', html):
            self.tokens.append(m.group(1))
        if not self.tokens:
            for m in re.finditer(r'content="([^"]+)"\s+name="csrf_token"', html):
                self.tokens.append(m.group(1))
        if not self.tokens:
            try:
                data = self._request("GET", "webserver/token", None, init=True)
                if isinstance(data, dict):
                    token = str(data.get("token") or "")
                    if len(token) > 32:
                        token = token[32:]
                    if token:
                        self.tokens.append(token)
            except RouterError:
                pass

    def _headers(self) -> dict[str, str]:
        h = {
            "Referer": self.base + "/",
            "Origin": self.base,
            "X-Requested-With": "XMLHttpRequest",
            "_ResponseSource": "Broswer",
        }
        if self.tokens:
            h["__RequestVerificationToken"] = self.tokens[0]
        return h

    def _request(self, method: str, path: str, fields: Optional[dict[str, Any]] = None,
                 init: bool = False) -> Any:
        url = f"{self.base}/api/{path}"
        headers = self._headers()
        data = None
        if method == "POST":
            body = "".join(
                f"<{k}>{_xml_escape(v)}</{k}>" for k, v in (fields or {}).items()
            )
            data = (XML_DECL + "<request>" + body + "</request>").encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        try:
            r = self.session.request(method, url, data=data, headers=headers,
                                     timeout=self.timeout, verify=False,
                                     allow_redirects=True)
        except requests.RequestException as exc:
            raise RouterError("network", f"اتصال به مودم ممکن نشد: {exc.__class__.__name__}", "network") from exc

        # Rotate CSRF tokens exactly like the WebUI does.
        one = r.headers.get("__RequestVerificationTokenone")
        two = r.headers.get("__RequestVerificationTokentwo")
        single = r.headers.get("__RequestVerificationToken")
        if one or single:
            self.tokens.clear()
            if one:
                self.tokens.append(one)
            if two:
                self.tokens.append(two)
            elif single and not one:
                self.tokens.append(single)
        elif method == "POST" and len(self.tokens) > 1:
            self.tokens.rotate(-1)

        body = r.text or ""
        if r.status_code >= 400:
            raise RouterError(f"http{r.status_code}", f"مودم کد HTTP {r.status_code} برگرداند", "network")
        ctype = (r.headers.get("Content-Type") or "").lower()
        data: Any
        if "json" in ctype or body.lstrip().startswith(("{", "[")):
            try:
                data = json.loads(body)
            except Exception:
                data = {}
        else:
            data = self._xml_fields(body)
        if isinstance(data, dict) and "code" in data and len(data) <= 4:
            code = str(data.get("code"))
            raise RouterError(code, self._describe(code), classify(code))
        return data

    def _xml_fields(self, body: str) -> Any:
        text = body.strip()
        if not text:
            return {}
        try:
            root = ET.fromstring(text.encode("utf-8"))
        except ET.ParseError:
            return {"_text": text[:400]}
        tag = root.tag.split("}")[-1]
        if tag == "error":
            code = root.findtext("code") or "unknown"
            message = self._describe(str(code))
            remain = root.findtext("remaincount")
            wait = root.findtext("waittime") or root.findtext("tobelockedtime")
            if str(code) in ("108007", "108010") and wait not in (None, ""):
                message += f" — تا {to_fa(wait)} دقیقه دیگر"
            elif remain not in (None, ""):
                message += f" — فرصت باقی‌مانده: {to_fa(remain)}"
            elif wait not in (None, "", "0"):
                message += f" — زمان انتظار: {to_fa(wait)} دقیقه"
            raise RouterError(str(code), message, classify(str(code)))
        children = list(root)
        if not children:
            return root.text or ""
        out: dict[str, Any] = {}
        for c in children:
            name = c.tag.split("}")[-1]
            if len(c):
                out[name] = [self._element_dict(g) for g in c]
            else:
                val = c.text or ""
                if name in out:
                    if not isinstance(out[name], list):
                        out[name] = [out[name]]
                    out[name].append(val)
                else:
                    out[name] = val
        return out

    @staticmethod
    def _element_dict(el: ET.Element) -> dict[str, Any]:
        d: dict[str, Any] = {}
        for c in el:
            name = c.tag.split("}")[-1]
            if len(c):
                d[name] = [HuaweiCPE._element_dict(x) for x in c]
            else:
                d[name] = c.text or ""
        return d

    @staticmethod
    def _describe(code: str) -> str:
        return {
            "108001": "نام کاربری یا رمز عبور اشتباه است",
            "108002": "نام کاربری یا رمز عبور اشتباه است",
            "108006": "نام کاربری یا رمز عبور اشتباه است",
            "108007": "ورود بیش از حد تلاش شده؛ چند دقیقه صبر کنید",
            "108010": "ورود بیش از حد تلاش شده؛ چند دقیقه صبر کنید",
            "108003": "یک نشست دیگر باز است؛ از پنل مودم خارج شوید",
            "108005": "یک نشست دیگر باز است؛ از پنل مودم خارج شوید",
            "108009": "یک نشست دیگر باز است؛ از پنل مودم خارج شوید",
            "100002": "نشست مودم منقضی شده است",
            "125002": "نشست مودم منقضی شده است",
            "125003": "نشست مودم منقضی شده است",
            "100003": "این قابلیت برای حساب فعلی مجاز نیست",
        }.get(code, f"خطای مودم ({code})")

    def _get(self, path: str) -> Any:
        return self._request("GET", path)

    def _post(self, path: str, fields: dict[str, Any]) -> Any:
        return self._request("POST", path, fields)

    # ---- auth --------------------------------------------------------
    def state(self) -> dict[str, Any]:
        try:
            data = self._get("user/state-login")
            return data if isinstance(data, dict) else {}
        except RouterError:
            return {}

    def login(self, force: bool = False) -> None:
        if self._logged_in and not force:
            return
        if not self.password:
            raise RouterError("nopass", "رمز عبور مودم تنظیم نشده است", "auth")
        self.initialize()
        st = self.state()
        if not force and str(st.get("State", "")) == "0":
            self._logged_in = True
            return

        nonce = secrets.token_hex(32)
        challenge = self._post("user/challenge_login", {
            "username": self.username,
            "firstnonce": nonce,
            "mode": 1,
        })
        if not isinstance(challenge, dict):
            raise RouterError("challenge", "پاسخ چالش ورود مودم نامعتبر است", "auth")
        server_nonce = str(_first(challenge, "servernonce", "serverNonce") or "")
        if not server_nonce or not server_nonce.startswith(nonce):
            raise RouterError("challenge", "چالش ورود مودم تأیید نشد", "auth")
        salt = str(_first(challenge, "salt") or "")
        iterations = safe_int(_first(challenge, "iterations"), 0)
        if not salt or iterations <= 0:
            raise RouterError("challenge", "پارامترهای ورود مودم ناقص است", "auth")

        salted = _pbkdf2(self.password, salt, iterations)
        client_key = _hmac(salted, b"Client Key")
        stored_key = hashlib.sha256(client_key).digest()
        auth_msg = f"{nonce},{server_nonce},{server_nonce}"
        client_sig = _hmac(stored_key, auth_msg.encode("utf-8"))
        proof = bytes(a ^ b for a, b in zip(client_key, client_sig)).hex()

        body: dict[str, Any] = {"clientproof": proof, "finalnonce": server_nonce}
        if str(_first(challenge, "newType") or "") == "1":
            new_salt = str(_first(challenge, "newSalt") or "")
            new_iter = safe_int(_first(challenge, "newIterations"), 0)
            if new_salt and new_iter > 0:
                salted2 = _pbkdf2(self.password, new_salt, new_iter)
                new_stored = hashlib.sha256(_hmac(salted2, b"Client Key")).hexdigest()
                new_server = _hmac(salted2, b"Server Key").hex()
                body["hashOldNewPwd"] = hashlib.sha256(
                    (new_stored + new_server + proof).encode("utf-8")
                ).hexdigest()
                body["newStoredKey"] = new_stored
                body["newServerKey"] = new_server

        result = self._post("user/authentication_login", body)
        if isinstance(result, dict):
            signature = str(_first(result, "serversignature", "serverSignature") or "")
            if signature:
                server_key = _hmac(salted, b"Server Key")
                expected = _hmac(server_key, auth_msg.encode("utf-8")).hex()
                if not hmac.compare_digest(expected, signature.lower()):
                    raise RouterError("signature", "امضای سرور مودم تأیید نشد", "auth")
        self._logged_in = True

    def _with_relogin(self, fn):
        try:
            self.login()
            return fn()
        except RouterError as exc:
            if exc.kind == "session":
                self._logged_in = False
                self.login(force=True)
                return fn()
            raise

    # ---- data --------------------------------------------------------
    def fetch_hosts(self) -> list[HostStat]:
        def call():
            last_exc: Optional[RouterError] = None
            for path in ("system/HostInfo", "system/hostinfo", "lan/HostInfo",
                         "lan/host-info", "wlan/host-list"):
                try:
                    data = self._get(path)
                except RouterError as exc:
                    last_exc = exc
                    if exc.kind in ("forbidden", "error"):
                        continue
                    raise
                hosts = self._parse_hosts(data)
                if hosts:
                    return hosts
            if last_exc and last_exc.kind not in ("forbidden", "error"):
                raise last_exc
            return []
        return self._with_relogin(call)

    def _parse_hosts(self, data: Any) -> list[HostStat]:
        if isinstance(data, list):
            raw = data
        elif isinstance(data, dict):
            candidate = None
            for key in ("Host", "Hosts", "host", "hosts", "HostList", "hostlist"):
                if key in data:
                    candidate = data[key]
                    break
            if candidate is None:
                candidate = data
            raw = _as_list(candidate)
        else:
            raw = []
        out: list[HostStat] = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            mac = mac_norm(str(_first(item, "MACAddress", "MacAddress", "mac", "MAC") or ""))
            if not mac or len(mac) < 12:
                continue
            name = str(_first(item, "ActualName", "HostName", "hostname", "name", "HostName2") or "").strip()
            ip = str(_first(item, "IPAddress", "IpAddress", "ip", "IP") or "").split(";")[0].strip()
            iface = str(_first(item, "InterfaceType", "interfaceType", "Interface", "conn_type") or "")
            iface_l = iface.lower()
            if iface_l in ("0", "wifi", "wlan", "wireless", "2.4g", "5g"):
                conn = "wifi"
            elif iface_l in ("1", "ethernet", "lan", "wired"):
                conn = "lan"
            else:
                conn = iface
            tx_kb = safe_int(_first(item, "TxKBytes", "txKBytes", "TxKB", "TxBytes"), 0)
            rx_kb = safe_int(_first(item, "RxKBytes", "rxKBytes", "RxKB", "RxBytes"), 0)
            has_counters = any(
                str(k).lower() in ("txkbytes", "rxkbytes", "txbytes", "rxbytes", "txkb", "rxkb")
                for k in item.keys()
            )
            tx_bytes = tx_kb * 1024 if tx_kb else 0
            rx_bytes = rx_kb * 1024 if rx_kb else 0
            down = safe_int(_first(item, "DownRate", "downRate", "RxRate", "down_rate"), 0)
            up = safe_int(_first(item, "UpRate", "upRate", "TxRate", "up_rate"), 0)
            active = _truthy(_first(item, "Active", "active", "Online", "online"))
            out.append(HostStat(
                mac=mac, ip=ip, hostname=name, conn_type=conn,
                ssid=str(_first(item, "SSID", "Ssid", "ssid") or ""),
                rx_bytes=rx_bytes, tx_bytes=tx_bytes,
                down_rate=max(0, down), up_rate=max(0, up),
                active=active, counters=has_counters, raw=item,
            ))
        return out

    def fetch_wan(self) -> WanStat:
        def call():
            traffic = self._get("monitoring/traffic-statistics")
            month = self._get("monitoring/month_statistics")
            plan = self._get("monitoring/start_date")
            if not isinstance(traffic, dict):
                traffic = {}
            if not isinstance(month, dict):
                month = {}
            if not isinstance(plan, dict):
                plan = {}
            wan = WanStat(
                total_rx=safe_int(_first(traffic, "TotalDownload")),
                total_tx=safe_int(_first(traffic, "TotalUpload")),
                month_rx=safe_int(_first(month, "CurrentMonthDownload")),
                month_tx=safe_int(_first(month, "CurrentMonthUpload")),
                day_used=safe_int(_first(month, "CurrentDayUsed")),
                down_rate=safe_int(_first(traffic, "CurrentDownloadRate")),
                up_rate=safe_int(_first(traffic, "CurrentUploadRate")),
                month_clear=str(_first(month, "MonthLastClearTime") or ""),
            )
            quota = safe_int(_first(plan, "trafficmaxlimit"), 0)
            if quota <= 0:
                quota = parse_data_limit(str(_first(plan, "DataLimit") or ""))
            wan.quota_bytes = quota
            wan.reset_day = safe_int(_first(plan, "StartDay"), 0)
            wan.raw = {"traffic": traffic, "month": month, "plan": plan}
            return wan
        return self._with_relogin(call)

    def fetch_info(self) -> RouterInfo:
        basic: dict[str, Any] = {}
        try:
            b = self._get("device/basic_information")
            if isinstance(b, dict):
                basic = b
        except RouterError:
            pass
        info: dict[str, Any] = {}
        try:
            i = self._get("device/information")
            if isinstance(i, dict):
                info = i
        except RouterError:
            pass
        status: dict[str, Any] = {}
        try:
            s = self._get("monitoring/status")
            if isinstance(s, dict):
                status = s
        except RouterError:
            pass
        signal: dict[str, Any] = {}
        try:
            sig = self._get("device/signal")
            if isinstance(sig, dict):
                signal = sig
        except RouterError:
            pass
        model = str(_first(info, "DeviceName") or _first(basic, "devicename")
                    or _first(basic, "spreadname_en") or "Huawei CPE")
        firmware = str(_first(info, "SoftwareVersion") or "")
        network_type = str(_first(status, "CurrentNetworkTypeEx") or
                           _first(status, "CurrentNetworkType") or "")
        signal_icon = str(_first(status, "SignalIcon") or "")
        rsrp = _first(signal, "rsrp", "nr_rsrp")
        if rsrp:
            signal_icon = f"{signal_icon} (RSRP {rsrp})" if signal_icon else f"RSRP {rsrp}"
        self.info_cache = RouterInfo(
            model=model,
            firmware=firmware,
            network_type=network_type,
            signal=signal_icon,
            wan_ip=str(_first(info, "WanIPAddress") or _first(status, "WanIPAddress") or ""),
            uptime=safe_int(_first(status, "Uptime"), 0),
        )
        return self.info_cache

    def test(self) -> dict[str, Any]:
        self.login(force=True)
        info = self.fetch_info()
        hosts = self.fetch_hosts()
        wan = self.fetch_wan()
        return {
            "ok": True,
            "router": info.as_dict(),
            "hosts": len(hosts),
            "wan": wan.as_dict(),
        }
