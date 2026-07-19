@echo off
setlocal enabledelayedexpansion

echo ========================================================
echo   SearXNG Setup — AliasAgent
echo ========================================================
echo.

REM Check prerequisites
echo [1/5] Checking prerequisites...

where python >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Python 3.7+ is required but not found in PATH.
    echo Install Python from https://www.python.org/downloads/
    exit /b 1
)

python -c "import sys; sys.exit(0 if sys.version_info >= (3,7) else 1)"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Python 3.7+ is required. Detected version is older.
    exit /b 1
)
echo   Python OK

where git >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: git is required but not found in PATH.
    exit /b 1
)
echo   git OK

REM Clone SearXNG
echo.
echo [2/5] Cloning SearXNG (depth=1)...
set "SEARXNG_DIR=%~dp0..\tools\searxng"

if exist "%SEARXNG_DIR%" (
    echo   SearXNG directory already exists, skipping clone
) else (
    git clone --depth 1 https://github.com/searxng/searxng.git "%SEARXNG_DIR%"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: Failed to clone SearXNG.
        echo Try setting proxy: git config --global http.proxy http://127.0.0.1:7890
        exit /b 1
    )
    echo   Clone complete
)

REM Create virtual environment
echo.
echo [3/5] Setting up Python virtual environment...

cd /d "%SEARXNG_DIR%"

if not exist "venv" (
    python -m venv venv
    if %ERRORLEVEL% neq 0 (
        echo ERROR: Failed to create virtual environment.
        exit /b 1
    )
)

call venv\Scripts\activate.bat

REM Install prerequisites
echo.
echo [4/5] Installing dependencies...

pip install pyyaml msgspec typing-extensions pybind11 tomli tzdata
if %ERRORLEVEL% neq 0 (
    echo WARNING: Some pip packages may have failed.
    echo Try: pip install --proxy http://127.0.0.1:7890 <package>
)

pip install -e .
if %ERRORLEVEL% neq 0 (
    echo WARNING: pip install -e . failed.
    echo Try: pip install --proxy http://127.0.0.1:7890 -e .
)

REM Generate settings.yml
echo.
echo [5/5] Generating settings.yml...

python -c "
import yaml, secrets, os
settings = {
    'use_default_settings': True,
    'server': {
        'port': 8888,
        'bind_address': '127.0.0.1',
        'secret_key': secrets.token_hex(32),
    },
    'search': {
        'formats': ['html', 'json'],
    },
    'engines': [
        {
            'name': 'bing',
            'engine': 'bing',
            'base_url': 'https://cn.bing.com',
            'disabled': False,
        },
    ],
    'redis': {
        'url': False,
    },
}
# Use valkey.url instead of redis.url for newer SearXNG versions
settings['valkey'] = {'url': False}
os.makedirs(os.path.dirname('%SEARXNG_DIR%\searx\settings.yml'), exist_ok=True)
with open('%SEARXNG_DIR%\searx\settings.yml', 'w') as f:
    yaml.dump(settings, f, default_flow_style=False)
print('  settings.yml generated')
"

echo.
echo ========================================================
echo   SearXNG setup complete!
echo.
echo   Start SearXNG:
echo     cd tools\searxng
echo     venv\Scripts\activate
echo     python -m searx.webapp
echo.
echo   Then access: http://localhost:8888
echo   Search JSON API: http://localhost:8888/search?q=test^&format=json
echo.
echo   Stop: Ctrl+C
echo   Update: cd tools\searxng ^&^& git pull
echo ========================================================

endlocal
