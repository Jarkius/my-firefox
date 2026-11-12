@echo off
rem Double-click (or run) to build the custom portable Firefox end to end.
rem Arguments are passed to build.ps1, e.g.:  build.cmd -Policy devtools -Ref release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
