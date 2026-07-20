@echo off
cd /d "%~dp0"

echo === AliasAgent ===
echo.

:: ── Step 1: Build Flutter app ──
echo [1/4] Building...
call flutter build windows --debug
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Build failed
    pause
    exit /b 1
)

:: ── Step 2: Build Release sidecar and copy DLLs for testing ──
echo [2/4] Building Release sidecar...
cmake --build sidecar\build\windows --config Release > nul 2>&1
copy /Y "sidecar\build\windows\Release\sidecar.dll" . > nul 2>&1
copy /Y "sidecar.dll" "build\windows\x64\runner\Debug\" > nul 2>&1
copy /Y "build\windows\x64\runner\Debug\libcurl.dll" . > nul 2>&1
copy /Y "build\windows\x64\runner\Debug\zlib1.dll"  . > nul 2>&1

:: ── Step 3: Smoke test ──
echo [3/4] Smoke test...
call flutter test test\unit\sidecar_bridge_test.dart
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Smoke test FAILED
    pause
    exit /b 1
)

:: ── Step 4: Launch ──
echo [4/4] Launching...
start "AliasAgent" "build\windows\x64\runner\Debug\alias_agent.exe"
echo Done.
pause
