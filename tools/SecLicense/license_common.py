"""SecToggle 设备授权 — 与 iOS SecLicense / SecToggle 共用同一算法。"""
from __future__ import annotations

import hashlib
import hmac
import re
from datetime import datetime, timedelta

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


def validate_expiry_yyyymmdd(raw: str) -> str:
    s = re.sub(r"[^0-9]", "", raw.strip())
    if len(s) != 8:
        raise ValueError("到期日须为 YYYYMMDD，例如 20261231")
    datetime.strptime(s, "%Y%m%d")
    return s


def expiry_from_days(days: int) -> str:
    if days < 1:
        raise ValueError("有效天数须 >= 1")
    return (datetime.now() + timedelta(days=days)).strftime("%Y%m%d")


def expiry_display(yyyymmdd: str | None) -> str:
    if not yyyymmdd:
        return "永久（旧版码）"
    s = validate_expiry_yyyymmdd(yyyymmdd)
    return f"{s[0:4]}-{s[4:6]}-{s[6:8]}"


def is_expired(yyyymmdd: str | None) -> bool:
    if not yyyymmdd:
        return False
    s = validate_expiry_yyyymmdd(yyyymmdd)
    end = datetime.strptime(s, "%Y%m%d").replace(hour=23, minute=59, second=59)
    return datetime.now() > end


def format_groups(hex16: str) -> str:
    h = re.sub(r"[^0-9a-fA-F]", "", hex16).upper()
    if len(h) != 16:
        raise ValueError("签名段须为 16 位十六进制")
    return "-".join(h[i : i + 4] for i in range(0, 16, 4))


def parse_activation_code(raw: str) -> tuple[str, str | None]:
    compact = re.sub(r"[^0-9A-Fa-f]", "", raw.strip())
    if len(compact) == 16:
        return compact.upper(), None
    if len(compact) == 24:
        hex16 = compact[:16].upper()
        expiry = compact[16:]
        validate_expiry_yyyymmdd(expiry)
        return hex16, expiry

    text = raw.strip().upper().replace(" ", "")
    parts = [p for p in text.split("-") if p]
    if len(parts) == 4:
        hex16 = "".join(parts)
        if len(hex16) != 16:
            raise ValueError("激活码格式无效")
        return hex16, None
    if len(parts) == 5:
        hex16 = "".join(parts[:4])
        expiry = parts[4]
        if len(hex16) != 16 or len(expiry) != 8 or not expiry.isdigit():
            raise ValueError("激活码格式无效，应为 XXXX-XXXX-XXXX-XXXX-YYYYMMDD")
        validate_expiry_yyyymmdd(expiry)
        return hex16, expiry
    raise ValueError("激活码格式无效，应为 XXXX-XXXX-XXXX-XXXX-YYYYMMDD")


def canonical_activation_code(raw: str) -> str:
    hex16, expiry = parse_activation_code(raw)
    base = format_groups(hex16)
    return f"{base}-{expiry}" if expiry else base


def expiry_from_code(raw: str) -> str | None:
    return parse_activation_code(raw)[1]


def device_code_short(uuid_str: str) -> str:
    digest = hashlib.sha256(normalize_uuid(uuid_str).encode("utf-8")).hexdigest().upper()
    return "-".join(digest[i : i + 4] for i in range(0, 12, 4))


def generate_activation_code(
    device_uuid: str,
    secret: str = DEFAULT_SECRET,
    *,
    expiry_yyyymmdd: str | None = None,
    valid_days: int | None = 365,
) -> str:
    uuid_norm = normalize_uuid(device_uuid)
    if expiry_yyyymmdd is None:
        if valid_days is None:
            raise ValueError("须指定 expiry_yyyymmdd 或 valid_days")
        expiry_yyyymmdd = expiry_from_days(valid_days)
    else:
        expiry_yyyymmdd = validate_expiry_yyyymmdd(expiry_yyyymmdd)

    payload = f"{uuid_norm}|{expiry_yyyymmdd}".encode("utf-8")
    mac = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).digest()
    return f"{format_groups(mac[:8].hex())}-{expiry_yyyymmdd}"


def verify_activation_code(device_uuid: str, code: str, secret: str = DEFAULT_SECRET) -> bool:
    try:
        hex16, expiry = parse_activation_code(code)
        uuid_norm = normalize_uuid(device_uuid)
        key = secret.encode("utf-8")

        if expiry is None:
            mac = hmac.new(key, uuid_norm.encode("utf-8"), hashlib.sha256).digest()
            expected = format_groups(mac[:8].hex())
            return hmac.compare_digest(expected, format_groups(hex16))

        if is_expired(expiry):
            return False
        payload = f"{uuid_norm}|{expiry}".encode("utf-8")
        mac = hmac.new(key, payload, hashlib.sha256).digest()
        expected = format_groups(mac[:8].hex())
        return hmac.compare_digest(expected, format_groups(hex16))
    except ValueError:
        return False
