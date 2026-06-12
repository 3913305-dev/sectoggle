# 交叉编译 SecToggle.dylib (arm64-ios) 并打包 IPA
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tools = Join-Path $Root "tools"
$SecToggle = Join-Path $Root "SecToggle"
$SdkDir = Join-Path $Tools "iPhoneOS15.6.sdk"

function Find-Zig {
    $candidates = @(
        (Join-Path $Tools "zig\zig-windows-x86_64-0.13.0\zig.exe"),
        (Join-Path $Tools "zig-windows-x86_64-0.13.0\zig.exe")
    )
    Get-ChildItem (Join-Path $Tools "zig*") -Recurse -Filter "zig.exe" -ErrorAction SilentlyContinue |
        ForEach-Object { $candidates += $_.FullName }
    foreach ($z in $candidates) {
        if (Test-Path $z) { return $z }
    }
    return $null
}

function Ensure-Sdk {
    if (Test-Path (Join-Path $SdkDir "usr\include\UIKit\UIKit.h")) {
        Write-Host "[build] SDK 已存在: $SdkDir"
        return
    }
    $sdksRepo = Join-Path $Tools "sdks"
    if (-not (Test-Path (Join-Path $sdksRepo ".git"))) {
        Write-Host "[build] 拉取 theos/sdks (sparse iPhoneOS15.6.sdk)..."
        git -C $Tools clone --filter=blob:none --sparse https://github.com/theos/sdks.git sdks 2>&1 | Write-Host
        git -C $sdksRepo sparse-checkout set iPhoneOS15.6.sdk 2>&1 | Write-Host
    }
    if (-not (Test-Path (Join-Path $sdksRepo "iPhoneOS15.6.sdk\usr\include\UIKit\UIKit.h"))) {
        throw "iPhoneOS15.6.sdk 下载不完整，请检查网络后重试"
    }
    Copy-Item -Recurse -Force (Join-Path $sdksRepo "iPhoneOS15.6.sdk") $SdkDir
}

function Ensure-Zig {
    $zig = Find-Zig
    if ($zig) { return $zig }
    $zip = Join-Path $Tools "zig.zip"
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 70000000) {
        Write-Host "[build] 下载 Zig 0.13.0..."
        curl.exe -L -o $zip "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    }
    Expand-Archive -Path $zip -DestinationPath $Tools -Force
    return (Find-Zig)
}

Write-Host "=== SecToggle 编译 + IPA 打包 ==="
Ensure-Sdk
$zig = Ensure-Zig
if (-not $zig) { throw "找不到 zig.exe" }
Write-Host "[build] Zig: $zig"

$srcFiles = @(
    (Join-Path $SecToggle "SecToggle.m"),
    (Join-Path $SecToggle "SecLicenseCore.m"),
    (Join-Path $SecToggle "SecDeviceID.m")
)
$out = Join-Path $SecToggle "SecToggle.dylib"
$libcTxt = Join-Path $Tools "ios_libc.txt"
@"
include_dir=$SdkDir/usr/include
sys_include_dir=$SdkDir/usr/include
crt_dir=
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
"@ | Set-Content -Encoding ASCII $libcTxt

$args = @(
    "cc",
    "-target", "aarch64-ios13.0",
    "-mcpu", "apple-a11",
    "-isysroot", $SdkDir,
    "-dynamiclib",
    "-fobjc-arc",
    "-framework", "UIKit",
    "-framework", "Foundation",
    "-framework", "CoreLocation",
    "-framework", "Security",
    "-install_name", "@executable_path/SecToggle.dylib",
    "-o", $out,
    @($srcFiles),
    "--sysroot", $SdkDir,
    "-F", "$SdkDir/System/Library/Frameworks",
    "-L", "$SdkDir/usr/lib"
)
Write-Host "[build] $($args -join ' ')"
& $zig @args
if ($LASTEXITCODE -ne 0) { throw "编译失败 exit=$LASTEXITCODE" }
if (-not (Test-Path $out)) { throw "未生成 $out" }
Write-Host "[build] 生成 $out ($((Get-Item $out).Length) bytes)"

python (Join-Path $Tools "pack_ipa.py")
if ($LASTEXITCODE -ne 0) { throw "打包失败" }
Write-Host "=== Done: SecToggle.dylib ==="
Write-Host "Re-inject with TrollFools on device."
