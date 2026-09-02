@echo off
cd /d "%~dp0"

set "APP_DIR=build\windows\x64\runner\Debug"
set "APP_EXE=%APP_DIR%\alias_agent.exe"
set "BUILD_LOG=%TEMP%\aliasagent_build.log"

echo === AliasAgent ===
echo.

:: ---- Step 1: Build Flutter app (self-healing) ----
echo [1/5] Building Flutter app...
call flutter build windows --debug
if errorlevel 1 goto build_retry
goto build_verify

:build_retry
echo [WARN] First build failed. Clearing stale native-assets caches and retrying...
:: A just-failed flutter build can briefly hold a handle on the caches; retry the
:: clear with a short delay so a transient lock does not abort the self-heal. The
:: dead native-asset reference persists in BOTH .dart_tool\flutter_build AND
:: .dart_tool\hooks_runner (the hook's output.json manifest), so clear both.
set /a ICLEAR=0
:clear_retry
if exist ".dart_tool\flutter_build" rd /s /q ".dart_tool\flutter_build" >nul 2>&1
if exist ".dart_tool\hooks_runner" rd /s /q ".dart_tool\hooks_runner" >nul 2>&1
if not exist ".dart_tool\flutter_build" if not exist ".dart_tool\hooks_runner" goto clear_ok
set /a ICLEAR+=1
if %ICLEAR% geq 5 goto clear_failed
ping -n 3 127.0.0.1 >nul 2>&1
goto clear_retry
:clear_ok
call flutter pub get
if errorlevel 1 goto pubget_failed
echo [INFO] Retrying build...
call flutter build windows --debug
if errorlevel 1 goto build_classify
echo [INFO] FIRST_BUILD_FAILED_BUT_RETRY_RECOVERED
goto build_verify

:build_classify
echo [ERROR] Retry still failed. Capturing verbose log to localize the cause...
call flutter build windows --debug -v > "%BUILD_LOG%" 2>&1
call :classify "%BUILD_LOG%"
echo.
echo [ERROR] Verbose build log: %BUILD_LOG%
pause
exit /b 1

:build_verify
:: ---- Step 2: Validate build products + refresh Debug libs ----
echo [2/5] Validating build products...
if not exist "%APP_EXE%" goto no_exe
if not exist "%APP_DIR%\sidecar.dll" goto no_sidecar

echo [3/5] Refreshing Debug sidecar and dependency DLLs to project root...
copy /Y "%APP_DIR%\sidecar.dll" . >nul
if errorlevel 1 goto copy_failed
for %%f in ("%APP_DIR%\libcurl*.dll" "%APP_DIR%\zlib*.dll") do (
  if exist "%%~f" (
    copy /Y "%%~f" . >nul
    if errorlevel 1 goto copy_failed
  )
)

:: ---- Step 4: Smoke test ----
echo [4/5] Smoke test...
call flutter test test\unit\sidecar_bridge_test.dart
if errorlevel 1 goto smoke_failed

:: ---- Step 5: Launch ----
echo [5/5] Launching...
if not exist "%APP_EXE%" goto no_exe
start "AliasAgent" "%APP_EXE%"
echo Done.
pause
exit /b 0

:: ---- Error branches ----
:clear_failed
echo [ERROR] Failed to clear the build cache. Please clean it manually and retry.
pause
exit /b 1

:pubget_failed
echo [ERROR] flutter pub get failed (possible network / dependency issue).
pause
exit /b 1

:no_exe
echo [ERROR] Missing app executable: %APP_EXE%
echo Make sure the Flutter build ran fine; if the sidecar is missing it is likely because vcpkg was not found.
pause
exit /b 1

:no_sidecar
echo [ERROR] Missing sidecar library: %APP_DIR%\sidecar.dll
echo It is likely that vcpkg was not found so the sidecar could not be built.
echo Check VCPKG_ROOT / the VCPKG_TOOLCHAIN value in the CMake cache.
pause
exit /b 1

:copy_failed
echo [ERROR] Failed to copy the sidecar / dependency DLLs to the project root.
pause
exit /b 1

:smoke_failed
echo [ERROR] Smoke test failed. Check the sidecar API against the current build.
pause
exit /b 1

:: ---- Error-classification subroutine (code > network > unknown) ----
:: NOTE: no parenthesized if-blocks here; a paren or quote inside an echo
:: inside a ( ... ) block breaks cmd's block parser (". was unexpected").
:classify
set "LOG=%~1"
set "CLASS=unknown"
findstr /c:"fatal error C" /c:"error C" /c:"error LNK" /c:"unresolved external" "%LOG%" >nul 2>&1
if errorlevel 1 goto class_net_check
set "CLASS=code"
:class_net_check
findstr /c:"Could not download" /c:"Trying to retrieve" /c:"HandshakeException" /c:"timed out" /c:"network is unreachable" /c:"resolve host" "%LOG%" >nul 2>&1
if errorlevel 1 goto class_report
if not "%CLASS%"=="code" set "CLASS=network"
:class_report
if "%CLASS%"=="code" goto class_code
if "%CLASS%"=="network" goto class_network
echo [ERROR] Cause: unable to determine automatically.
echo          Open the log and read the first Error: or fatal error line.
exit /b 0
:class_code
echo [ERROR] Cause: a real code / compile error.
echo          Open the log and read the compiler line: fatal error C, error C, error LNK, unresolved external.
exit /b 0
:class_network
echo [ERROR] Cause: a network or download environment problem. Your app code is likely not at fault.
echo          Check your network and proxy settings, then retry.
exit /b 0
