@echo off
cd /d "%~dp0..\tools\searxng"
set SEARXNG_SETTINGS_PATH=%CD%\settings.yml
call venv\Scripts\activate.bat
echo SearXNG settings: %SEARXNG_SETTINGS_PATH%
echo Starting on http://localhost:8888 ...
echo.
python -m searx.webapp
pause
