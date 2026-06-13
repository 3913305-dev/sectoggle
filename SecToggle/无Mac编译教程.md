# 没有 Mac —— 3 分钟拿到 SecToggle.dylib

用 **GitHub 免费 Mac 云编译**，全程浏览器操作，不需要 Mac、不需要 Frida。

---

## 第一步：注册 / 登录 GitHub

打开 https://github.com ，没有账号就免费注册一个。

---

## 第二步：新建仓库并上传文件

1. 点右上角 **+** → **New repository**
2. 仓库名随便填，例如 `sectoggle-build`
3. 选 **Public**，不要勾选 README，点 **Create repository**
4. 在新仓库页面点 **uploading an existing file**
5. 把下面整个文件夹 **拖进去上传**：

```
ios/SecToggle/          ← SecToggle.m、Makefile 等
ios/.github/workflows/    ← build-sectoggle.yml
```

也可以直接上传本目录里的 **`SecToggle-upload.zip`**（已打包好上述文件）。

6. 点 **Commit changes**

---

## 第三步：运行编译

1. 仓库顶部点 **Actions**
2. 左侧选 **Build SecToggle.dylib**
3. 右侧 **Run workflow** → 绿色 **Run workflow**
4. 等约 **1～2 分钟**，出现绿色 ✓

---

## 第四步：下载 dylib

1. 点进刚跑完的那条 workflow
2. 页面底部 **Artifacts** → 下载 **SecToggle.dylib**
3. 解压得到 `SecToggle.dylib`

---

## 第五步：巨魔注入

1. 把 `SecToggle.dylib` 传到 iPhone
2. 打开 **TrollFools** → 选 **中邮司机帮**
3. 注入该 dylib → 杀进程重开 App
4. 左上角出现 **SEC 远程自动到达** 悬浮窗

详细注入说明见 [README.md](README.md)。

---

## 常见问题

**Q：Actions 是灰的 / 没有 Build SecToggle.dylib？**  
A：确认上传了 `.github/workflows/build-sectoggle.yml`，路径必须完全一致。

**Q：编译失败？**  
A：点进失败的 job 看日志，通常是文件没传全；重新上传 `SecToggle.m` 和 workflow 文件。

**Q：不想公开代码？**  
A：可以用 Private 仓库（GitHub 免费账号也支持 Private + Actions）。

**Q：没有 GitHub 账号也不想注册？**  
A：只能找有 Mac 的朋友帮忙编，或在 Mac 网吧 / 云 Mac 跑一条命令（见 README 方法 A）。

---

## 一条命令版（已装 git 时）

```powershell
cd C:\Users\Administrator\Desktop\ios
git init
git add SecToggle .github
git commit -m "add SecToggle"
git branch -M main
git remote add origin https://github.com/你的用户名/sectoggle-build.git
git push -u origin main
```

然后去 GitHub → Actions → Run workflow → 下载 Artifacts。
