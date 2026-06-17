# TPlayerFakeVIP — 巨魔内测插件

> 仅供 **你们自己的 TPlayer 内测包** 使用（Bundle ID: `com.twanjia.teslaplayer`）。  
> 注入后：登录即假 VIP，跳过表盘/会员接口校验，方便测功能而不是测支付。

---

## 做了什么

| 层级 | 行为 |
|------|------|
| 本地缓存 | 写入真实表盘 ID 列表（`amap`、`apple_map` 等 20+ 个），登录后每 10s 回写 |
| 登录 merge | `/auth/*/login` 明文响应 merge `is_vip` + `dial_unlocks`（保留 token） |
| 登录加密 | 加密登录 **不整包替换**（保留 token），触发 burst 回写本地解锁列表 |
| 网络 Hook | 拦截 `NSURLSession`，篡改以下接口响应 |
| | `/vip/checkVipStatus`、`/user/getUserInfo` → VIP + dial_unlocks |
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

1. 登录后进 **会员页** → 应显示已开通 / 终身
2. 进 **表盘** → 点以前要付费的表盘 → 应能直接用，不弹窗
3. **Console**（Mac 连 iPhone）过滤 `TPlayerFakeVIP`，应看到：
   - `v4 loaded enabled=1 (login merge + dial ids)`
   - `auth-encrypted pass-through + reseed`（登录加密，已触发回写）
   - `auth-merge url=...`（明文登录已 merge VIP）
   - `decrypt-bypass url=...`（checkVipStatus / getUserInfo 加密绕过）
   - `patch-json url=...`

## v4 表盘解锁修复（相对 v3）

| 问题 | v4 处理 |
|------|---------|
| 登录 `_dial_unlocks` 为空 | 明文登录 merge；加密登录 pass-through + 定时回写真实 dial ID |
| `["*"]` 通配符无效 | 改为 20+ 真实表盘 type ID |
| 首页读 AuthService 登录态 | 增强 `/user/getUserInfo` 假数据含 VIP + dial_unlocks |
| 登录不能整包替换 | 加密 `/auth/*` 仅 pass-through，不丢 token |

## v3 稳定性修复（若 v2 闪退）

v2 以下 hook 会导致崩溃，**v3 已全部移除**：

| 已移除 | 原因 |
|--------|------|
| `JSONDecoder.decode` hook | Swift 方法 ABI 不兼容，必崩 |
| `NSUserDefaults` 全局 swizzle | 大量 key 类型不匹配 |
| `NSJSONSerialization` 全局 hook | 误伤地图/配置等 JSON |
| 所有 teslaapi 默认假响应 | 破坏登录/车辆等接口 |
| hook `__NSURLSessionLocal` | 重复 hook 链崩溃 |

v3 仅保留：**NSURLSession 网络层 + 白名单 URL + 加密绕过**。

| 问题 | v2 处理 |
|------|---------|
| API 返回 `encrypted: true` 密文 | 整包替换为明文假 VIP 数据 |
| Swift `JSONDecoder` 不走旧 hook | 尝试 hook `decode:from:` + JSON 层补丁 |
| 仅 hook `NSURLSession` 基类 | 同时 hook `__NSURLSessionLocal` |
| `["*"]` 通配符可能无效 | 主要靠 `is_vip=1` 走会员全解锁 |
| 未覆盖 `/user/getUserInfo` | 已加入假 VIP 响应 |

## 若仍无效

1. **完全杀掉 App** 再开（多任务划掉）
2. **退出账号重新登录**
3. TrollFools 确认库状态为 **已启用**，且 Bundle 为 `com.twanjia.teslaplayer`
4. Console 里若只有 `v2 loaded` 没有 `decrypt-bypass` / `patch-json`，说明网络栈仍未 hook 到，把日志发我再加规则

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
