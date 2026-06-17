#Requires -Version 5.1
# 推送 TPlayerFakeVIP 到 GitHub，触发 Actions 云端编译
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Test-Path ".git")) {
    Write-Host "请在 sectoggle 仓库根目录运行 git init / clone 后再执行"
    exit 1
}

git add TPlayerFakeVIP .github/workflows/build-tplayer-fakevip.yml .gitignore
git status
$msg = "TPlayerFakeVIP: fake VIP test dylib for TPlayer internal build"
git commit -m $msg 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "无新改动或 commit 失败" }

git push origin main
Write-Host ""
Write-Host "已推送。打开 Actions 下载 TPlayerFakeVIP.dylib："
Write-Host "https://github.com/3913305-dev/sectoggle/actions/workflows/build-tplayer-fakevip.yml"
