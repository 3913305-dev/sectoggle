# SecToggle 插件 — 巨魔注入指南

有 **TrollStore（巨魔）** 时，不需要重打包 IPA，也 **不需要 Frida**。  
把编译好的 `SecToggle.dylib` 注入到「中邮司机帮」即可。

## 你需要的东西

| 文件 | 说明 |
|------|------|
| `SecToggle.dylib` | 插件本体（arm64，需编译一次） |
| 中邮司机帮 | 已通过巨魔安装，Bundle ID: `com.copote.yygk.app.driver` |
| TrollFools | 巨魔生态下的 dylib 注入工具 |

## 一、编译 SecToggle.dylib

`.dylib` 必须在 **Mac** 或带 iOS SDK 的 Linux 上编译（Windows 无法直接编 arm64-iOS）。

### 方法 A：Mac + Xcode（最简单）

```bash
cd SecToggle
xcrun -sdk iphoneos clang -arch arm64 \
  -dynamiclib -fobjc-arc \
  -framework UIKit -framework Foundation -framework CoreLocation \
  -install_name @executable_path/SecToggle.dylib \
  -o SecToggle.dylib SecToggle.m \
  -miphoneos-version-min=13.0
```

编译成功后当前目录会有 `SecToggle.dylib`（约几十 KB～几百 KB）。

### 方法 B：Theos（越狱/巨魔开发常用）

```bash
# 安装 Theos: https://theos.dev/docs/Installation-macOS.html
export THEOS=~/theos
git clone https://github.com/theos/sdks.git $THEOS/sdks   # 复制 iPhoneOS*.sdk 进去

cd SecToggle
make
# 产物: .theos/obj/debug/SecToggle.dylib
```

### 方法 C：GitHub Actions 自动编译（无 Mac 时）

1. 把 `ios` 文件夹推到 GitHub 仓库
2. 打开仓库 → **Actions** → **Build SecToggle.dylib** → **Run workflow**
3. 跑完后在 **Artifacts** 里下载 `SecToggle.dylib`

```bash
# 或本地有 gh CLI：
gh workflow run build-sectoggle.yml
gh run list --workflow=build-sectoggle.yml
gh run download <run-id> -n SecToggle.dylib
```

## 二、用 TrollFools 注入

1. 用 **TrollStore** 安装「中邮司机帮」（你现有的 3.5.6 破解包即可）。
2. 用 **TrollStore** 安装 **TrollFools**（GitHub: `Lessica/TrollFools`）。
3. 把 `SecToggle.dylib` 传到 iPhone（AirDrop / 文件 App / Filza 等）。
4. 打开 **TrollFools** → 选择 **中邮司机帮**（或 Bundle ID `com.copote.yygk.app.driver`）。
5. 点 **Inject / 注入** → 选择 `SecToggle.dylib` → 确认。
6. **完全杀掉** App 后重新打开。

## 三、使用说明

1. 打开 App，进入 **任务详情**（让接口返回站点列表，插件会自动解析 `n_zdjd` / `n_zdwd`）。
2. 屏幕左上角会出现 **「SEC 远程自动到达」** 悬浮窗（可拖动）。
3. 打开开关 → 选择「下一站」→ 在 App 内点 **到达/签到**。
4. 插件会在发请求前改 GPS 坐标、在 `setHTTPBody` 前改包（绕过爱加密签名前改 body）。

## 四、验证是否注入成功

- 打开 App 后应看到黑色半透明悬浮面板。
- 若用 Mac + 控制台：`log stream --predicate 'eventMessage CONTAINS "SecToggle"'` 应能看到 `[SecToggle] Hooks 安装完成`。

## 五、常见问题

| 现象 | 处理 |
|------|------|
| 没有悬浮窗 | 确认 TrollFools 注入成功；杀进程重开；部分 iOS 需给 App 一次前台权限 |
| 开关开了仍失败 | 先打开任务详情让站点被解析；爱加密若升级需更新 hook 点 |
| 注入后闪退 | dylib 架构必须是 **arm64**；不要用模拟器版 |
| TrollFools 找不到 App | 确认是巨魔安装的包，不是 App Store 版 |

## 六、卸载

TrollFools 里对该 App **Remove injection / 移除注入**，或删除注入记录后重装 App。

---

**说明**：本插件仅用于你方授权的安全测试。源码见同目录 `SecToggle.m`。
