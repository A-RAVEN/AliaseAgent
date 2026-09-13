# Refresh the built sidecar DLL into the repo root, where `flutter test` loads it.
#
# NOTE (corrected): this does NOT introduce a new mechanism. The project's own entry
# point already does it -- run.bat step [3/5] "Refreshing Debug sidecar and dependency
# DLLs to project root" (`copy /Y "%APP_DIR%\sidecar.dll" .`), followed by the
# DLL-dependent smoke test in step [4/5]. The canonical way to validate is:
#
#     run.bat
#
# This script exists for the case where you only want the tests and therefore skip
# run.bat's build + launch steps: it performs the SAME refresh as a standalone,
# idempotent command, so the guard test can name an exact fix instead of leaving you
# with confusing failures.
#
# Why that matters (2026-09-12): `flutter test` loads the DLL by the BARE NAME
# 'sidecar.dll' (lib/services/sidecar_bridge.dart), which resolves to the REPO ROOT
# copy. Running `cmake --build ...` + `flutter test` directly -- bypassing run.bat
# step 3 -- left that copy stale, and the real-DLL suites then failed with 15
# confusing "Failed to lookup symbol 'browser_available'" errors that read like a
# code regression. The lesson is "use the project's entry point", not "add a script";
# this file just makes the bypass safe.
#
# Usage: powershell -NoProfile -File scripts\sync_sidecar_dll.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Newest first: the Debug build is what the test suite and the debug app use.
$candidates = @(
    'sidecar\build\windows\Debug\sidecar.dll',
    'build\windows\x64\runner\Debug\sidecar.dll',
    'sidecar\build\windows\Release\sidecar.dll',
    'build\windows\x64\runner\Release\sidecar.dll'
) | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path $_ }

if (-not $candidates) {
    Write-Output 'SYNC-SKIPPED: no built sidecar.dll found (build the C++ side first)'
    Write-Output '  cmake --build sidecar/build/windows --config Debug'
    exit 0
}

$src = $candidates |
    ForEach-Object { Get-Item $_ } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

$dst = Join-Path $root 'sidecar.dll'
$srcHash = (Get-FileHash $src.FullName -Algorithm SHA256).Hash
$dstHash = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm SHA256).Hash } else { '' }

if ($srcHash -eq $dstHash) {
    Write-Output ("SYNC-OK: sidecar.dll already current ({0})" -f $src.LastWriteTime)
    exit 0
}

Copy-Item $src.FullName $dst -Force
Write-Output ("SYNCED: {0}" -f $src.FullName.Replace("$root\", ''))
Write-Output ("     -> {0}" -f $dst)
Write-Output ("     built {0} (the copy in place was {1})" -f `
    $src.LastWriteTime, $(if ($dstHash) { 'different' } else { 'missing' }))
