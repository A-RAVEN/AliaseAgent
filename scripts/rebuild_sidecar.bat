@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM AliasAgent Clean Rebuild Script (Batch)
REM Rebuilds C++ sidecar DLL via Flutter CMake's sidecar_build target,
REM then deploys the DLL to additional locations.
REM ============================================================================

set "BUILD_TYPE=%~1"
if "%BUILD_TYPE%"=="" set "BUILD_TYPE=Debug"
set "RUN_AFTER=%~2"

set "PROJECT_ROOT=%~dp0.."
set "SID_SRC=%PROJECT_ROOT%\sidecar"
set "SID_BUILD=%SID_SRC%\build\windows"
set "FLUTTER_BUILD_DIR=%PROJECT_ROOT%\build\windows\x64"
set "RUNNER_DIR=%FLUTTER_BUILD_DIR%\runner\%BUILD_TYPE%"
set "WINDOWS_DIR=%PROJECT_ROOT%\windows"
set "TEST_DIR=%PROJECT_ROOT%\test"

REM ============================================================================
REM 1. Clean previous build artifacts (prevents generator mismatch)
REM ============================================================================
echo [*] Cleaning %SID_BUILD% ...
if exist "%SID_BUILD%" rmdir /s /q "%SID_BUILD%"
echo      Clean complete.

REM ============================================================================
REM 2. Ensure Flutter CMake build directory is configured
REM ============================================================================
if not exist "%FLUTTER_BUILD_DIR%\CMakeCache.txt" (
    echo [X] Flutter CMake build dir not configured: %FLUTTER_BUILD_DIR%
    echo     Run 'flutter build windows --debug' first to generate the CMake cache,
    echo     or 'flutter run -d windows' to let Flutter configure it automatically.
    exit /b 1
)

REM ============================================================================
REM 3. Build sidecar via Flutter CMake target
REM ============================================================================
echo [*] Building sidecar via Flutter CMake (sidecar_build target^)...
cmake --build "%FLUTTER_BUILD_DIR%" --config "%BUILD_TYPE%" --target sidecar_build
if %ERRORLEVEL% neq 0 ( echo [X] Build failed & exit /b 1 )

set "DLL_PATH=%SID_BUILD%\%BUILD_TYPE%\sidecar.dll"
if not exist "%DLL_PATH%" (
    echo [X] DLL not found: %DLL_PATH%
    exit /b 1
)
echo      Build succeeded: %DLL_PATH%

REM ============================================================================
REM 4. Deploy DLL to all target directories
REM ============================================================================
echo [*] Deploying DLL...

REM Runner dir (used by flutter run)
copy /y "%DLL_PATH%" "%RUNNER_DIR%\sidecar.dll" >nul 2>&1
echo    -^> %RUNNER_DIR%\sidecar.dll

REM windows/ dir (used by flutter build for bundling)
copy /y "%DLL_PATH%" "%WINDOWS_DIR%\sidecar.dll" >nul 2>&1
echo    -^> %WINDOWS_DIR%\sidecar.dll

REM Project root (for testing)
copy /y "%DLL_PATH%" "%PROJECT_ROOT%\sidecar.dll" >nul 2>&1
echo    -^> %PROJECT_ROOT%\sidecar.dll

REM test/ dir
if exist "%TEST_DIR%" (
    copy /y "%DLL_PATH%" "%TEST_DIR%\sidecar.dll" >nul 2>&1
    echo    -^> %TEST_DIR%\sidecar.dll
)

REM Dependency DLLs
for %%d in (libcurl.dll zlib1.dll) do (
    if exist "%WINDOWS_DIR%\%%d" (
        copy /y "%WINDOWS_DIR%\%%d" "%RUNNER_DIR%\%%d" >nul 2>&1
        copy /y "%WINDOWS_DIR%\%%d" "%PROJECT_ROOT%\%%d" >nul 2>&1
    )
)

echo [*] DLL deployed.

REM ============================================================================
REM 5. Optional: Flutter run
REM ============================================================================
if /i "%RUN_AFTER%"=="run" (
    echo [*] Starting Flutter app...
    cd /d "%PROJECT_ROOT%"
    flutter run -d windows
)

echo [*] Next: flutter run -d windows

endlocal