# ============================================================================
# AliasAgent Clean Rebuild Script (PowerShell)
# Rebuilds C++ sidecar DLL via Flutter CMake's sidecar_build target,
# then deploys the DLL to additional locations.
# ============================================================================
param(
    [ValidateSet("Debug", "Release", "Profile")]
    [string]$BuildType = "Debug",

    [switch]$Run
)

$ErrorActionPreference = "Stop"

$ProjectRoot    = "$PSScriptRoot\.."
$SidSrc         = "$ProjectRoot\sidecar"
$SidBuild       = "$SidSrc\build\windows"
$FlutterBuildDir = "$ProjectRoot\build\windows\x64"
$RunnerDir      = "$FlutterBuildDir\runner\$BuildType"
$WindowsDir     = "$ProjectRoot\windows"
$TestDir        = "$ProjectRoot\test"

# ============================================================================
# 1. Clean previous build artifacts (prevents generator mismatch)
# ============================================================================
Write-Host "[*] Cleaning $SidBuild ..." -ForegroundColor Green
if (Test-Path $SidBuild) {
    Remove-Item -Recurse -Force $SidBuild
}
Write-Host "     Clean complete."

# ============================================================================
# 2. Ensure Flutter CMake build directory is configured
# ============================================================================
if (-not (Test-Path "$FlutterBuildDir\CMakeCache.txt")) {
    Write-Error @"
Flutter CMake build dir not configured: $FlutterBuildDir
Run 'flutter build windows --debug' first to generate the CMake cache,
or 'flutter run -d windows' to let Flutter configure it automatically.
"@
    exit 1
}

# ============================================================================
# 3. Build sidecar via Flutter CMake target
# ============================================================================
Write-Host "[*] Building sidecar via Flutter CMake (sidecar_build target)..." -ForegroundColor Green
cmake --build "$FlutterBuildDir" --config "$BuildType" --target sidecar_build
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit 1 }

$DllPath = "$SidBuild\$BuildType\sidecar.dll"
if (-not (Test-Path $DllPath)) {
    Write-Error "DLL not found: $DllPath"
    exit 1
}
Write-Host "     Build succeeded: $DllPath" -ForegroundColor Green

# ============================================================================
# 4. Deploy DLL to all target directories
# ============================================================================
Write-Host "[*] Deploying DLL..." -ForegroundColor Green

$targets = @(
    "$RunnerDir\sidecar.dll",
    "$WindowsDir\sidecar.dll",
    "$ProjectRoot\sidecar.dll"
)
if (Test-Path $TestDir) {
    $targets += "$TestDir\sidecar.dll"
}

foreach ($t in $targets) {
    $destDir = Split-Path $t -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    Copy-Item -Force "$DllPath" "$t"
    Write-Host "  -> $t"
}

# Copy dependency DLLs
foreach ($dll in @("libcurl.dll", "zlib1.dll")) {
    $src = "$WindowsDir\$dll"
    if (Test-Path $src) {
        Copy-Item -Force $src "$RunnerDir\$dll" -ErrorAction SilentlyContinue
        Copy-Item -Force $src "$ProjectRoot\$dll" -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# 5. Optional: Flutter run
# ============================================================================
Push-Location $ProjectRoot
try {
    if ($Run) {
        Write-Host "[*] Starting Flutter app..." -ForegroundColor Green
        flutter run -d windows
    }
} finally {
    Pop-Location
}

Write-Host "=== Done! ===" -ForegroundColor Green