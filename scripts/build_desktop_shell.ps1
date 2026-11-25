# 构建 Windows 桌面壳（change `windows-desktop-shell` 任务 4.3 / design D6）。
#
# 用法（必须从仓库根跑；脚本自己会切到仓库根）：
#   powershell -NoProfile -File scripts\build_desktop_shell.ps1
#
# 产出：shell\dist\AliasAgent.Desktop.exe（双击即用；自包含，不需要用户另装 .NET 桌面运行时）
#
# 首次运行要下载 net10 的两个运行时包（Microsoft.NETCore.App.Runtime.win-x64 /
# Microsoft.WindowsDesktop.App.Runtime.win-x64，上百 MB，需网络）；离线必失败，
# 脚本会把这类失败归类成「网络/依赖源原因」，而不是含糊的「构建失败」。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'pubspec.yaml'))) {
    Write-Host "[build] 错误：$repoRoot 看起来不是仓库根（缺 pubspec.yaml）" -ForegroundColor Red
    exit 1
}

# 关键：`dotnet` 只从**当前工作目录**向上找 global.json，所以必须真的站在仓库根。
Set-Location $repoRoot

Write-Host "═══════════════════════════════════════════"
Write-Host "  构建 AliasAgent 桌面壳（自包含 win-x64）"
Write-Host "═══════════════════════════════════════════"
Write-Host "  仓库根：$repoRoot"

# ── 1/4 检查 dotnet 与 SDK ────────────────────────────────
Write-Host ""
Write-Host "[1/4] 检查 dotnet 与钉住的 SDK"
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetCommand) {
    Write-Host "[build] 错误：PATH 上找不到 dotnet。装 .NET SDK（本仓库用 11.0.100 构建 net10 目标）后重试。" -ForegroundColor Red
    exit 1
}
Write-Host "  dotnet：$($dotnetCommand.Source)"
$sdkVersion = (& dotnet --version).Trim()
$sdkExit = $LASTEXITCODE
if ($sdkExit -ne 0) {
    Write-Host "[build] 错误：dotnet --version 失败（exit=$sdkExit）。" -ForegroundColor Red
    exit 1
}
Write-Host "  实际 SDK 版本：$sdkVersion"

$globalJsonPath = Join-Path $repoRoot 'global.json'
if (-not (Test-Path $globalJsonPath)) {
    Write-Host "[build] 错误：仓库根缺 global.json（用来钉构建用的 SDK）。" -ForegroundColor Red
    exit 1
}
$globalJson = Get-Content -Raw -Path $globalJsonPath | ConvertFrom-Json
$pinnedSdk = [string]$globalJson.sdk.version
$rollForward = [string]$globalJson.sdk.rollForward
Write-Host "  global.json 钉住：$pinnedSdk（rollForward=$rollForward）"
$pinnedParts = $pinnedSdk.Split('.')
$actualParts = $sdkVersion.Split('.')
if ($pinnedParts.Length -lt 2 -or $actualParts.Length -lt 2) {
    Write-Host "[build] 错误：无法比较 SDK 版本（pinned=$pinnedSdk actual=$sdkVersion）。" -ForegroundColor Red
    exit 1
}
if ($pinnedParts[0] -ne $actualParts[0] -or $pinnedParts[1] -ne $actualParts[1]) {
    Write-Host "[build] 错误：实际 SDK $sdkVersion 与 global.json 钉住的 $pinnedSdk 大版本不一致（构建入口不可复现）。" -ForegroundColor Red
    exit 1
}
Write-Host "  ✔ SDK 与 global.json 一致（同一大版本）"

# ── 2/4 发布（自包含） ───────────────────────────────────
Write-Host ""
Write-Host "[2/4] dotnet publish（Release / win-x64 / self-contained）"
$publishLog = Join-Path $env:TEMP ("aliasagent_publish_" + [guid]::NewGuid().ToString('N') + ".log")
$publishArgs = @(
    'publish',
    'shell/AliasAgent.Desktop/AliasAgent.Desktop.csproj',
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', 'shell/dist'
)
Write-Host "  dotnet $($publishArgs -join ' ')"
& dotnet @publishArgs *>&1 | Tee-Object -FilePath $publishLog
$publishExit = $LASTEXITCODE
if ($publishExit -ne 0) {
    $output = ''
    if (Test-Path $publishLog) { $output = Get-Content -Raw -Path $publishLog }
    Write-Host ""
    Write-Host "[build] 错误：dotnet publish 失败（exit=$publishExit），已中止 —— 不产出半份产物。" -ForegroundColor Red
    $networkPatterns = @(
        'NU1', 'NU1101', 'NU1301', 'NETSDK1112', 'Unable to load the service index',
        'No such host is known', 'timed out', 'Connection refused', 'restore failed',
        '还原失败', '无法解析', '下载失败'
    )
    $isNetwork = $false
    foreach ($pattern in $networkPatterns) {
        if ($output -match [regex]::Escape($pattern)) { $isNetwork = $true; break }
    }
    if ($isNetwork) {
        Write-Host "[build] 归类：网络 / 依赖源原因（不是代码错误）。" -ForegroundColor Yellow
        Write-Host "        首次自包含发布要下载 net10 运行时包（Microsoft.NETCore.App.Runtime.win-x64、" -ForegroundColor Yellow
        Write-Host "        Microsoft.WindowsDesktop.App.Runtime.win-x64），上百 MB。检查网络 / 包源后重试。" -ForegroundColor Yellow
    } else {
        Write-Host "[build] 归类：代码 / 构建错误（看上面的 MSBuild 输出）。" -ForegroundColor Yellow
    }
    exit 1
}

# ── 3/4 校验产物 ────────────────────────────────────────
Write-Host ""
Write-Host "[3/4] 校验产物"
$exePath = Join-Path $repoRoot 'shell/dist/AliasAgent.Desktop.exe'
$loaderPath = Join-Path $repoRoot 'shell/dist/WebView2Loader.dll'
$missing = @()
if (-not (Test-Path $exePath)) { $missing += 'AliasAgent.Desktop.exe' }
if (-not (Test-Path $loaderPath)) { $missing += 'WebView2Loader.dll' }
if ($missing.Count -gt 0) {
    Write-Host ("[build] 错误：产物缺失：" + ($missing -join ', ') + " —— 不打印成功。") -ForegroundColor Red
    exit 1
}
Write-Host "  ✔ shell/dist/AliasAgent.Desktop.exe"
Write-Host "  ✔ shell/dist/WebView2Loader.dll"

# ── 4/4 完成 ────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════"
Write-Host "  ✔ 构建完成" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════"
Write-Host "  双击这个文件启动："
Write-Host "    $exePath"
Write-Host ""
Write-Host "  无窗口自检（不开窗、不建托盘）："
Write-Host ('    "' + $exePath + '" --selftest')
Write-Host ""
exit 0
