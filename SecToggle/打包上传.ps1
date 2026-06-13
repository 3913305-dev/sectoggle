# 打包 SecToggle 上传 GitHub 用
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Out = Join-Path $Root "SecToggle-upload.zip"

$staging = Join-Path $env:TEMP "sectoggle-upload"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path "$staging\SecToggle" -Force | Out-Null
New-Item -ItemType Directory -Path "$staging\.github\workflows" -Force | Out-Null

Copy-Item "$Root\SecToggle\*" "$staging\SecToggle\" -Recurse
Copy-Item "$Root\.github\workflows\build-sectoggle.yml" "$staging\.github\workflows\"

if (Test-Path $Out) { Remove-Item $Out -Force }
Compress-Archive -Path "$staging\*" -DestinationPath $Out -Force
Remove-Item $staging -Recurse -Force

Write-Host "已生成: $Out"
Write-Host "上传到 GitHub 新仓库后，Actions -> Run workflow -> 下载 SecToggle.dylib"
