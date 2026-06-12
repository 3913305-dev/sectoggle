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
    expiry_display,
    expiry_from_code,
    expiry_from_days,
    generate_activation_code,
    normalize_uuid,
    verify_activation_code,
)


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("SecToggle 发码工具")
        self.geometry("580x480")
        self.minsize(500, 440)
        self._build_ui()

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 6}
        frm = ttk.Frame(self, padding=12)
        frm.pack(fill=tk.BOTH, expand=True)

        ttk.Label(
            frm,
            text="设备 UUID（SEC 面板或 SecLicense App 里复制）",
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

        ttk.Label(frm, text="有效天数").grid(row=3, column=0, sticky="w", **pad)
        days_row = ttk.Frame(frm)
        days_row.grid(row=3, column=1, sticky="w", **pad)
        self.days_var = tk.IntVar(value=365)
        ttk.Spinbox(days_row, from_=1, to=3650, textvariable=self.days_var, width=8).pack(side=tk.LEFT)
        ttk.Label(days_row, text="  天").pack(side=tk.LEFT)
        self.expiry_preview_var = tk.StringVar(value="—")
        ttk.Label(frm, text="预计到期").grid(row=4, column=0, sticky="w", **pad)
        ttk.Label(frm, textvariable=self.expiry_preview_var, font=("Consolas", 11)).grid(
            row=4, column=1, sticky="w", **pad
        )
        self.days_var.trace_add("write", lambda *_: self._refresh_expiry_preview())
        self._refresh_expiry_preview()

        ttk.Label(frm, text="密钥（须与 iOS 端一致）").grid(row=5, column=0, sticky="w", **pad)
        self.secret_var = tk.StringVar(value=DEFAULT_SECRET)
        ttk.Entry(frm, textvariable=self.secret_var, width=52, show="*").grid(
            row=6, column=0, columnspan=2, sticky="ew", **pad
        )

        btn_row = ttk.Frame(frm)
        btn_row.grid(row=7, column=0, columnspan=2, sticky="w", **pad)
        ttk.Button(btn_row, text="生成激活码", command=self._generate).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(btn_row, text="校验激活码", command=self._verify).pack(side=tk.LEFT)

        ttk.Label(frm, text="激活码", font=("Segoe UI", 10, "bold")).grid(
            row=8, column=0, columnspan=2, sticky="w", **pad
        )
        self.code_var = tk.StringVar()
        code_entry = ttk.Entry(frm, textvariable=self.code_var, width=52, font=("Consolas", 11))
        code_entry.grid(row=9, column=0, columnspan=2, sticky="ew", **pad)

        ttk.Button(frm, text="复制激活码", command=self._copy).grid(row=10, column=0, sticky="w", **pad)

        ttk.Separator(frm, orient=tk.HORIZONTAL).grid(
            row=11, column=0, columnspan=2, sticky="ew", pady=12
        )
        help_text = (
            "激活码格式：XXXX-XXXX-XXXX-XXXX-YYYYMMDD（末段为到期日）\n"
            "到期日当天 23:59:59 前有效；过期后需重新发码。"
        )
        ttk.Label(frm, text=help_text, wraplength=540, justify=tk.LEFT).grid(
            row=12, column=0, columnspan=2, sticky="w", **pad
        )

        frm.columnconfigure(1, weight=1)

    def _refresh_expiry_preview(self) -> None:
        try:
            days = int(self.days_var.get())
            self.expiry_preview_var.set(expiry_display(expiry_from_days(days)))
        except (ValueError, tk.TclError):
            self.expiry_preview_var.set("—")

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
            days = int(self.days_var.get())
            if not secret:
                raise ValueError("密钥不能为空")
            code = generate_activation_code(uuid_norm, secret, valid_days=days)
            self.code_var.set(code)
            self.short_var.set(device_code_short(uuid_norm))
            exp = expiry_from_code(code)
            self.expiry_preview_var.set(expiry_display(exp))
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
            exp = expiry_from_code(code)
            if ok:
                messagebox.showinfo("校验", f"激活码有效 ✓\n到期：{expiry_display(exp)}")
            else:
                messagebox.showwarning("校验", "激活码无效、已过期或 UUID 不匹配 ✗")
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
    parser.add_argument("--days", type=int, default=365, help="有效天数")
    parser.add_argument("--expiry", help="到期日 YYYYMMDD")
    parser.add_argument("--verify", metavar="CODE", help="校验激活码")
    ns = parser.parse_args(args)
    try:
        if ns.verify:
            ok = verify_activation_code(ns.uuid, ns.verify, ns.secret)
            exp = expiry_from_code(ns.verify)
            print("OK" if ok else "FAIL")
            if exp:
                print(f"到期: {expiry_display(exp)}")
            return 0 if ok else 1
        if ns.expiry:
            code = generate_activation_code(ns.uuid, ns.secret, expiry_yyyymmdd=ns.expiry)
        else:
            code = generate_activation_code(ns.uuid, ns.secret, valid_days=ns.days)
        print(code)
        print(f"短码: {device_code_short(ns.uuid)}")
        print(f"到期: {expiry_display(expiry_from_code(code))}")
        return 0
    except ValueError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
