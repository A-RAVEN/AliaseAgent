# Capture the compaction live test's temp DB while it still exists.
#
# Why this is needed: `integration_test/compact_quality_live_test.dart` opens its own
# DB in a temp dir (`DatabaseService.openAt(tempDir.path)` -> `<dir>\aliasagent.db`)
# and DELETES it in `tearDown`. The console output is not a substitute: the test's
# `dumpContext` truncates the messages JSON to 2000 chars, so the verbatim history is
# not recoverable from the log. Copying the DB during the run is the only way to get
# the real 原文 (and the persisted summary_nodes) out.
#
# Usage (start this FIRST, then run the test in another shell):
#   powershell -NoProfile -File tools\capture_compact_db.ps1 -DurationSec 900
#
# The newest snapshot is kept at $OutDir (default %TEMP%\compact_db_captured).
param(
    [int]$DurationSec = 900,
    [int]$IntervalMs = 400,
    [string]$OutDir = "$env:TEMP\compact_db_captured"
)

$ErrorActionPreference = 'Continue'
$tmp = [System.IO.Path]::GetTempPath()
$deadline = (Get-Date).AddSeconds($DurationSec)
$copies = 0
$lastSrc = ''

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Output "watching $tmp for aliasagent_compact_* (up to ${DurationSec}s)"
while ((Get-Date) -lt $deadline) {
    $dir = Get-ChildItem $tmp -Directory -Filter 'aliasagent_compact_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($dir) {
        $db = Join-Path $dir.FullName 'aliasagent.db'
        if (Test-Path $db) {
            # Copy the DB and its SQLite side files by NAME, one at a time, tolerating
            # each one's disappearance. Do NOT glob the directory: a live writer creates
            # and deletes `aliasagent.db-journal` between two frames, so a wildcard copy
            # expands to an entry that is already gone and the whole capture dies with
            # "Could not find file ...aliasagent.db-journal" (measured twice on
            # 2026-10-03, exit code 1, nothing captured).
            Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
            foreach ($name in @('aliasagent.db', 'aliasagent.db-wal', 'aliasagent.db-shm', 'aliasagent.db-journal')) {
                $src = Join-Path $dir.FullName $name
                try {
                    if (Test-Path $src) { Copy-Item $src $OutDir -Force -ErrorAction Stop }
                } catch {
                    # A transient side file vanished mid-copy: skip it, the next tick
                    # re-reads the directory and picks up the committed state.
                }
            }
            $copies++
            $lastSrc = $dir.FullName
        }
    }
    Start-Sleep -Milliseconds $IntervalMs
}

$db = Join-Path $OutDir 'aliasagent.db'
if (Test-Path $db) {
    Write-Output ("CAPTURED {0} copies; last source {1}" -f $copies, $lastSrc)
    Write-Output ("DB={0} ({1:N0} bytes)" -f $db, (Get-Item $db).Length)
    Get-ChildItem $OutDir -File | ForEach-Object { "  {0}  {1:N0} bytes" -f $_.Name, $_.Length }
} else {
    Write-Output "NOTHING-CAPTURED (the test never created a DB, or it finished before this started)"
}
