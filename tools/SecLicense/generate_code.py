#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SecToggle 发码工具 — Windows 图形界面（Python 3.8+，无需第三方库）"""

from __future__ import annotations

import sys
import tkinter as tk
from tkinter import messagebox, ttk

from license_common import (
    DEFAULT_SECRET,
    device_code_short,
    generate_activation_code,
    normalize_uuid,
    verify_activation_code,
)


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("SecToggle 发码工具")
        self.geometry("560x420")
        self.minsize(480, 380)
        self._build_ui()

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 6}
        frm = ttk.Frame(self, padding=12)
        frm.pack(fill=tk.BOTH, expand=True)

        ttk.Label(
            frm,
            text="设备 UUID（用户在 SecLicense App 里复制）",
            font=("Segoe UI", 10, "bold"),
        ).grid(row=0, column=0, columnspan=2, sticky="w", **pad)

        self.uuid_var = tk.StringVar()
        uuid_entry = ttk.Entry(frm, textvariable=self.uuid_var, width=52)
        uuid_entry.grid(row=1, column=0, columnspan=2, sticky="ew", **pad)
        uuid_entry.bind("<KeyRelease>", lambda _e: self._refresh_short())

        ttk.Label(frm, text="短码核对（可选）").grid(row=2, column=0, sticky="w", **pad)
        self.short_var = tk.StringVar(value="—")
        ttk.Label(frm, textvariable=self.short_var, font=("Consolas", 11)).grid(
            row=2, column=1, sticky="w", **pad
        )

        ttk.Label(frm, text="密钥（须与 iOS 端一致）").grid(row=3, column=0, sticky="w", **pad)
        self.secret_var = tk.StringVar(value=DEFAULT_SECRET)
        ttk.Entry(frm, textvariable=self.secret_var, width=52, show="*").grid(
            row=4, column=0, columnspan=2, sticky="ew", **pad
        )

        btn_row = ttk.Frame(frm)
        btn_row.grid(row=5, column=0, columnspan=2, sticky="w", **pad)
        ttk.Button(btn_row, text="生成激活码", command=self._generate).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(btn_row, text="校验激活码", command=self._verify).pack(side=tk.LEFT)

        ttk.Label(frm, text="激活码", font=("Segoe UI", 10, "bold")).grid(
            row=6, column=0, columnspan=2, sticky="w", **pad
        )
        self.code_var = tk.StringVar()
        code_entry = ttk.Entry(frm, textvariable=self.code_var, width=52, font=("Consolas", 12))
        code_entry.grid(row=7, column=0, columnspan=2, sticky="ew", **pad)

        ttk.Button(frm, text="复制激活码", command=self._copy).grid(row=8, column=0, sticky="w", **pad)

        ttk.Separator(frm, orient=tk.HORIZONTAL).grid(
            row=9, column=0, columnspan=2, sticky="ew", pady=12
        )
        help_text = (
            "流程：iPhone 安装 SecLicense（巨魔）→ 复制设备 UUID → 粘贴到上方 → 生成激活码\n"
            "发给用户后在 SecLicense 里输入并保存。抹机后 Keychain UUID 会变，需重新发码。"
        )
        ttk.Label(frm, text=help_text, wraplength=520, justify=tk.LEFT).grid(
            row=10, column=0, columnspan=2, sticky="w", **pad
        )

        frm.columnconfigure(1, weight=1)

    def _refresh_short(self) -> None:
        raw = self.uuid_var.get().strip()
        if not raw:
            self.short_var.set("—")
            return
        try:
            self.short_var.set(device_code_short(raw))
        except ValueError:
            self.short_var.set("格式无效")

    def _generate(self) -> None:
        try:
            uuid_norm = normalize_uuid(self.uuid_var.get())
            secret = self.secret_var.get().strip()
            if not secret:
                raise ValueError("密钥不能为空")
            code = generate_activation_code(uuid_norm, secret)
            self.code_var.set(code)
            self.short_var.set(device_code_short(uuid_norm))
        except ValueError as exc:
            messagebox.showerror("错误", str(exc))

    def _verify(self) -> None:
        try:
            uuid_norm = normalize_uuid(self.uuid_var.get())
            secret = self.secret_var.get().strip()
            code = self.code_var.get()
            if not code.strip():
                raise ValueError("请先填写或生成激活码")
            ok = verify_activation_code(uuid_norm, code, secret)
            if ok:
                messagebox.showinfo("校验", "激活码与设备 UUID 匹配 ✓")
            else:
                messagebox.showwarning("校验", "激活码不匹配 ✗")
        except ValueError as exc:
            messagebox.showerror("错误", str(exc))

    def _copy(self) -> None:
        code = self.code_var.get().strip()
        if not code:
            messagebox.showwarning("提示", "没有可复制的激活码")
            return
        self.clipboard_clear()
        self.clipboard_append(code)
        messagebox.showinfo("已复制", code)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-c", "--cli"):
        return cli_main(sys.argv[2:])
    app = App()
    app.mainloop()
    return 0


def cli_main(args: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="SecToggle 发码 CLI")
    parser.add_argument("uuid", help="设备 UUID")
    parser.add_argument("--secret", default=DEFAULT_SECRET, help="HMAC 密钥")
    parser.add_argument("--verify", metavar="CODE", help="校验激活码")
    ns = parser.parse_args(args)
    try:
        if ns.verify:
            ok = verify_activation_code(ns.uuid, ns.verify, ns.secret)
            print("OK" if ok else "FAIL")
            return 0 if ok else 1
        code = generate_activation_code(ns.uuid, ns.secret)
        print(code)
        print(f"短码: {device_code_short(ns.uuid)}")
        return 0
    except ValueError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
