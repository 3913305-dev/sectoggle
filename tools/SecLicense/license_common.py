"""SecToggle 设备授权 — 与 iOS SecLicense / SecToggle 共用同一算法。"""
from __future__ import annotations

import hashlib
import hmac
import re

# 发码端与 iOS 校验端必须一致；部署前请改成自己的密钥。
DEFAULT_SECRET = "SecToggle-License-2026-ChangeMe"

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def normalize_uuid(raw: str) -> str:
    s = raw.strip()
    s = s.replace(" ", "").replace("\n", "").replace("\r", "")
    if _UUID_RE.match(s):
        return s.lower()
    compact = re.sub(r"[^0-9a-fA-F]", "", s)
    if len(compact) != 32:
        raise ValueError("请输入 32 位 UUID（可带或不带连字符）")
    return (
        f"{compact[0:8]}-{compact[8:12]}-{compact[12:16]}-"
        f"{compact[16:20]}-{compact[20:32]}"
    ).lower()


def normalize_activation_code(raw: str) -> str:
    s = re.sub(r"[^0-9a-fA-F]", "", raw.strip())
    if len(s) != 16:
        raise ValueError("激活码应为 16 位十六进制（XXXX-XXXX-XXXX-XXXX）")
    return s.upper()


def format_groups(hex16: str) -> str:
    h = hex16.upper()
    return "-".join(h[i : i + 4] for i in range(0, 16, 4))


def device_code_short(uuid_str: str) -> str:
    """便于人工核对的短码（SHA256 前 12 位 hex）。"""
    digest = hashlib.sha256(normalize_uuid(uuid_str).encode("utf-8")).hexdigest().upper()
    return "-".join(digest[i : i + 4] for i in range(0, 12, 4))


def generate_activation_code(device_uuid: str, secret: str = DEFAULT_SECRET) -> str:
    uuid_norm = normalize_uuid(device_uuid)
    key = secret.encode("utf-8")
    mac = hmac.new(key, uuid_norm.encode("utf-8"), hashlib.sha256).digest()
    return format_groups(mac[:8].hex())


def verify_activation_code(device_uuid: str, code: str, secret: str = DEFAULT_SECRET) -> bool:
    try:
        expected = generate_activation_code(device_uuid, secret)
        got = format_groups(normalize_activation_code(code))
        return hmac.compare_digest(expected, got)
    except ValueError:
        return False
