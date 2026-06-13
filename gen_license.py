#!/usr/bin/env python3
"""本地授权工具：密钥与 App 核心定位常量绑定，解析设备码并生成激活卡密。"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import re
import struct
import sys
from datetime import datetime

# 必须与 LocationBypassHelper / FakeLocationHub / GeocodeHelper 一致
ROUTE_STEP_M = 25.0
FENCE_JITTER_MAX_M = 35.0
DRIVE_SPEED_MIN_MS = 60.0 / 3.6
FENCE_SPEED_MAX_MS = 8
LICENSE_FRAG_A = "siji-sec"
LICENSE_FRAG_B = "fake-loc-hub-v2"
LICENSE_FRAG_C = "geo|geo_zddm|0.0005"

B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def derive_core_key() -> bytes:
    """与 LocationBypassHelper.licenseMasterKey() 相同。"""
    seed = (
        f"{LICENSE_FRAG_A}|{ROUTE_STEP_M:.3f}|{FENCE_JITTER_MAX_M:.1f}|"
        f"{LICENSE_FRAG_B}|{LICENSE_FRAG_C}|"
        f"{int(DRIVE_SPEED_MIN_MS * 1000)}|{FENCE_SPEED_MAX_MS ^ 0x5A3C}"
    )
    return hashlib.sha256(seed.encode("utf-8")).digest()


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def expand_stream(key: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        out.extend(hmac_sha256(key, f"lb-stream-{counter}".encode("utf-8")))
        counter += 1
    return bytes(out[:length])


def xor_stream(data: bytes, key: bytes) -> bytes:
    stream = expand_stream(key, len(data))
    return bytes(a ^ b for a, b in zip(data, stream))


def b32_encode(data: bytes) -> str:
    buffer = 0
    bits = 0
    out = []
    for b in data:
        buffer = (buffer << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            out.append(B32[(buffer >> bits) & 31])
    if bits:
        out.append(B32[(buffer << (5 - bits)) & 31])
    return "".join(out)


def b32_decode(encoded: str) -> bytes:
    s = re.sub(r"[^A-Z2-7]", "", encoded.upper())
    buffer = 0
    bits = 0
    out = bytearray()
    for c in s:
        val = B32.index(c)
        buffer = (buffer << 5) | val
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((buffer >> bits) & 0xFF)
    return bytes(out)


def format_groups(raw: str) -> str:
    parts = [raw[i : i + 4] for i in range(0, len(raw), 4)]
    return "-".join(parts)


def parse_device_code(code: str) -> tuple[str, str, str]:
    text = _extract_b32_payload(code)
    packed = b32_decode(text)
    if len(packed) <= 6:
        raise ValueError("设备码长度无效，请复制完整 DC1- 设备码")
    cipher = packed[:-6]
    mac = packed[-6:]
    key = derive_core_key()
    expect = hmac_sha256(key, cipher + b"dc-v1")[:6]
    if mac != expect:
        raise ValueError("设备码校验失败（核心密钥不匹配或数据损坏）")
    plain = xor_stream(cipher, key).decode("utf-8")
    parts = _parse_v1_payload(plain)
    return parts[1], parts[2], parts[3]


def _normalize_dashes(text: str) -> str:
    for ch in "–—−‐‑‒―－":
        text = text.replace(ch, "-")
    return text


def _extract_b32_payload(code: str) -> str:
    text = _normalize_dashes(code.strip().upper()).replace(" ", "")
    if "DC1" in text:
        text = text.split("DC1", 1)[1]
        if text.startswith("-"):
            text = text[1:]
    return re.sub(r"[^A-Z2-7]", "", text)


def _parse_v1_payload(plain: str) -> list[str]:
    if not plain.startswith("V1|"):
        raise ValueError(f"设备码内容无效: {plain!r}")
    rest = plain[3:]
    parts = rest.split("|", 2)
    if len(parts) != 3:
        raise ValueError("设备码内容无效（字段不完整，请重新复制完整设备码）")
    return ["V1", parts[0], parts[1], parts[2]]


def ymd_from_date(date_str: str) -> int:
    dt = datetime.strptime(date_str.strip(), "%Y-%m-%d")
    return dt.year * 10000 + dt.month * 100 + dt.day


def build_activation(name: str, plate: str, device_id: str, expiry_ymd: int) -> str:
    sign_input = f"V1|{name}|{plate}|{device_id}|{expiry_ymd}".encode("utf-8")
    key = derive_core_key()
    sig = hmac_sha256(key, sign_input)[:10]
    packed = struct.pack(">I", expiry_ymd) + sig
    return "AK1-" + format_groups(b32_encode(packed))


def cmd_decode(args: argparse.Namespace) -> int:
    name, plate, device = parse_device_code(args.device_code)
    print("解析成功")
    print(f"  姓名: {name}")
    print(f"  车牌: {plate}")
    print(f"  设备: {device}")
    return 0


def cmd_gen(args: argparse.Namespace) -> int:
    name, plate, device = parse_device_code(args.device_code)
    expiry = ymd_from_date(args.expire)
    card = build_activation(name, plate, device, expiry)
    print("激活卡密（发给司机）")
    print(card)
    print()
    print(f"  姓名: {name}")
    print(f"  车牌: {plate}")
    print(f"  到期: {args.expire}")
    return 0


def cmd_keyinfo(_: argparse.Namespace) -> int:
    key = derive_core_key()
    print("核心派生密钥 seed 参数（与 dex 内一致，勿改除非同步改 Java）:")
    print(f"  ROUTE_STEP_M={ROUTE_STEP_M}")
    print(f"  FENCE_JITTER_MAX_M={FENCE_JITTER_MAX_M}")
    print(f"  FRAG_B={LICENSE_FRAG_B}")
    print(f"  FRAG_C={LICENSE_FRAG_C}")
    print(f"  SHA256[:16]={key[:16].hex()}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="中邮司机帮 SEC 本地授权工具（核心密钥绑定版）")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_decode = sub.add_parser("decode", help="仅解析设备码")
    p_decode.add_argument("device_code", help="司机发来的 DC1- 设备码")
    p_decode.set_defaults(func=cmd_decode)

    p_gen = sub.add_parser("gen", help="解析设备码并生成激活卡密")
    p_gen.add_argument("device_code", help="司机发来的 DC1- 设备码")
    p_gen.add_argument(
        "--expire",
        required=True,
        help="到期日，格式 YYYY-MM-DD，例如 2026-12-31",
    )
    p_gen.set_defaults(func=cmd_gen)

    p_key = sub.add_parser("keyinfo", help="显示核心派生密钥信息")
    p_key.set_defaults(func=cmd_keyinfo)

    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
