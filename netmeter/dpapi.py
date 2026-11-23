"""Windows DPAPI helpers to keep the router password out of plain text."""
from __future__ import annotations

import base64
import ctypes
import os
import sys
from ctypes import wintypes

_IS_WINDOWS = os.name == "nt"


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _make_blob(data: bytes):
    buf = ctypes.create_string_buffer(data, len(data))
    return _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf


if _IS_WINDOWS:
    _crypt32 = ctypes.windll.crypt32
    _kernel32 = ctypes.windll.kernel32
    _crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(_DATA_BLOB), wintypes.LPCWSTR, ctypes.POINTER(_DATA_BLOB),
        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_DATA_BLOB),
    ]
    _crypt32.CryptProtectData.restype = wintypes.BOOL
    _crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_DATA_BLOB), ctypes.POINTER(wintypes.LPWSTR), ctypes.POINTER(_DATA_BLOB),
        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_DATA_BLOB),
    ]
    _crypt32.CryptUnprotectData.restype = wintypes.BOOL
    _kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    _kernel32.LocalFree.restype = ctypes.c_void_p


def protect(plain: str) -> str:
    if not plain:
        return ""
    raw = plain.encode("utf-8")
    if not _IS_WINDOWS:
        return "b64:" + base64.b64encode(raw).decode("ascii")
    blob_in, _buf = _make_blob(raw)
    blob_out = _DATA_BLOB()
    ok = _crypt32.CryptProtectData(
        ctypes.byref(blob_in), "NetMeter", None, None, None,
        0x01,  # CRYPTPROTECT_UI_FORBIDDEN
        ctypes.byref(blob_out),
    )
    if not ok:
        raise OSError(ctypes.get_last_error(), "CryptProtectData failed")
    try:
        encrypted = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        _kernel32.LocalFree(ctypes.cast(blob_out.pbData, ctypes.c_void_p))
    return "dpapi:" + base64.b64encode(encrypted).decode("ascii")


def unprotect(token: str) -> str:
    if not token:
        return ""
    token = token.strip()
    if token.startswith("b64:"):
        try:
            return base64.b64decode(token[4:]).decode("utf-8")
        except Exception:
            return ""
    if token.startswith("dpapi:") and _IS_WINDOWS:
        try:
            encrypted = base64.b64decode(token[6:])
        except Exception:
            return ""
        blob_in, _buf = _make_blob(encrypted)
        blob_out = _DATA_BLOB()
        ok = _crypt32.CryptUnprotectData(
            ctypes.byref(blob_in), None, None, None, None,
            0x01, ctypes.byref(blob_out),
        )
        if not ok:
            return ""
        try:
            raw = ctypes.string_at(blob_out.pbData, blob_out.cbData)
        finally:
            _kernel32.LocalFree(ctypes.cast(blob_out.pbData, ctypes.c_void_p))
        try:
            return raw.decode("utf-8")
        except Exception:
            return ""
    # Legacy/plain value: keep compatibility and let the caller re-save it.
    return token
