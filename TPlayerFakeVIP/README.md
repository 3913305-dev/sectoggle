# TPlayerFakeVIP — 巨魔内测插件

> 仅供 **你们自己的 TPlayer 内测包** 使用（Bundle ID: `com.twanjia.teslaplayer`）。  
> 注入后：登录即假 VIP，跳过表盘/会员接口校验，方便测功能而不是测支付。

---

## 做了什么

| 层级 | 行为 |
|------|------|
| 本地缓存 | 写入 `dashboard_unlocked_dial_ids` / `dashboard_acceleration_effect_unlocked_ids` = `["*"]` |
| 网络 Hook | 拦截 `NSURLSession`，篡改以下接口响应 |
| | `/vip/checkVipStatus` → `is_vip: 1` 终身会员 |
| | `/vip/activateWithIAP` → 直接成功 |
| | `/effect/myUnlocks`、`/wallpaper/getMyUnlocks` → 全解锁 |
| | 其他 JSON 里递归把 `unlocked` / `is_vip` 改成 true |

默认 **开启**。可用 UserDefaults 关闭：

```bash
# 关闭（需越狱 shell / Filza 改 plist 或写 defaults）
defaults write com.twanjia.teslaplayer tp_fake_vip.enabled -bool false
```

---

## 方式 A：TrollFools 注入（推荐，免编译）

1. 在 **Mac** 上编译 dylib（见下方「编译」）
2. 把 `TPlayerFakeVIP.dylib` 传到 iPhone
3. 打开 **TrollFools** → 选择「特别玩家 / TPlayer」
4. 添加库 → 选 `TPlayerFakeVIP.dylib` → 启用
5. 强制关闭 App 再打开，登录账号

TrollFools 会把 dylib 写进 App 的 `Frameworks` 并用 `LC_LOAD_DYLIB` 加载。

---

## 方式 B：Theos .deb（越狱机）

```bash
# macOS
export THEOS=~/theos
cd TrollVIPTest
make package
# 安装
dpkg -i packages/com.twanjia.tplayerfakevip_1.0.0_iphoneos-arm64.deb
killall -9 tplayer
```

---

## 编译（macOS + Xcode CLT）

### 用 Theos（推荐）

```bash
export THEOS=~/theos   # https://github.com/theos/theos
cd TrollVIPTest
make
# 产物: .theos/obj/debug/TPlayerFakeVIP.dylib
```

### 不用 Theos

```bash
cd TrollVIPTest
# 需要 logos（Theos 自带）
$THEOS/bin/logos.pl Tweak.x > TPlayerFakeVIP_gen.m
chmod +x build_standalone.sh
./build_standalone.sh   # 会编译 TPlayerFakeVIP.m；可把 gen 文件替换进去
```

或直接用仓库里的 **`TPlayerFakeVIP.m`**（纯 ObjC，不依赖 Substrate 运行时，适合 TrollFools）：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -dynamiclib \
  -isysroot "$SDK" -arch arm64 -miphoneos-version-min=14.0 \
  -fobjc-arc -install_name "@rpath/TPlayerFakeVIP.dylib" \
  -framework Foundation -framework UIKit \
  -o TPlayerFakeVIP.dylib TPlayerFakeVIP.m
```

---

## 验证是否生效

1. 登录后进会员页，应显示已开通 / 终身
2. 表盘列表不再弹 `LockedDialOverlay` 付费窗（配合本地缓存）
3. Console 过滤：`TPlayerFakeVIP`

---

## 限制（必读）

1. **只改客户端**：若某个功能请求 Tesla 官方 API 或你们服务端另有硬校验，仍可能失败
2. **加密响应**：若接口返回 `"encrypted": true` 且 data 是密文，插件会尝试 **整包替换** 为明文假数据；若 App 校验签名/字段，可能需再补规则
3. **Swift async URLSession**：若 1.7.0 走了 `URLSession.shared.data(for:)` 等新 API，需再加 hook；当前覆盖 `dataTaskWithRequest/URL:completionHandler:`
4. **不要打进 App Store 包**，仅内测分发

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `TPlayerFakeVIP.m` | 纯 ObjC dylib，TrollFools 直接用 |
| `Tweak.x` | Theos / Logos 源码 |
| `TPlayerFakeVIP.plist` | 注入目标 Bundle |
| `Makefile` | Theos 工程 |
| `control` | deb 元数据 |

---

## 与 SecurityTestKit 的关系

- **SecurityTestKit**：源码内测，编译进 App（`INTERNAL_BUILD`）
- **TPlayerFakeVIP.dylib**：不改源码，巨魔注入现成 IPA

两套可以并存，不要发给正式用户。
