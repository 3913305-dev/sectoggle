# SecLicense 发码工具

基于 **Keychain UUID**（主设备码）+ **IDFV**（参考）的简易授权方案，供 SecToggle 测试使用。

## 组成

| 组件 | 说明 |
|------|------|
| `SecLicenseApp/` | iOS App，巨魔侧载，展示 UUID、输入激活码 |
| `generate_code.py` | Windows / Mac 发码 GUI |
| `发码工具.bat` | 双击启动 GUI |
| `license_common.py` | Python 与 iOS 共用算法 |
| `build_ipa.sh` | Mac 上打包 `SecLicense.ipa` |

## 使用流程

1. **中邮司机帮 + SecToggle**（推荐）：注入 dylib 后，在 **SEC 悬浮面板** 复制 UUID → Windows 发码 → 面板内激活。
2. **SecLicense 独立 App**（可选）：仅用于单独测试发码流程；其 UUID 与宿主 App **不通用**。
3. **Windows**：双击 `发码工具.bat` → 粘贴 UUID → **生成激活码**。
4. 把激活码发回用户 → 在 SecToggle 面板或 SecLicense App 输入 → **保存/激活**。

## Windows 发码

```bat
:: 图形界面
发码工具.bat

:: 或命令行
python generate_code.py --cli "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
python generate_code.py --cli "uuid..." --verify "XXXX-XXXX-XXXX-XXXX"
```

## 算法

- 设备标识：首次启动写入 Keychain 的 UUID（抹机/删 Keychain 会变）。
- 激活码：`HMAC-SHA256(密钥, 小写UUID)` 取前 8 字节 → `XXXX-XXXX-XXXX-XXXX`。
- 短码：`SHA256(UUID)` 前 12 位 hex，便于人工核对。

## 修改密钥（部署前必做）

以下两处必须改成**同一字符串**：

1. `license_common.py` → `DEFAULT_SECRET`
2. `SecLicenseApp/SecLicenseCore.m` → `kSecLicenseDefaultSecret`

Windows 发码工具界面里也可临时改密钥，但 iOS 端须重新编译 IPA。

## Mac 编译 IPA

```bash
cd tools/SecLicense
chmod +x build_ipa.sh
./build_ipa.sh
# 产物: build/SecLicense.ipa → TrollStore 安装
```

## 与 SecToggle 对接

SecToggle.dylib 已内置相同校验：**未授权不安装 Hook**，面板内可复制 UUID、输入激活码。密钥需与 `SecToggle/SecLicenseCore.m` 一致。

## 注意

- **Keychain 按 App 隔离**：SecToggle 发码 UUID 必须来自 **中邮司机帮内 SEC 面板**；SecLicense 独立 App 的 UUID 不能用于 SecToggle。
- IDFV 仅作展示；**发码以 Keychain UUID 为准**。
- 密钥不要提交到公开仓库；当前默认为占位符 `SecToggle-License-2026-ChangeMe`。
- 本工具仅用于授权安全测试。
