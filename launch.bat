@echo off
rem Portable launcher: isolated profile next to firefox.exe.
set MOZ_CRASHREPORTER_DISABLE=1
set MOZ_DISABLE_AUTO_SAFE_MODE=1
if not exist "%~dp0profile" mkdir "%~dp0profile"
start "" "%~dp0firefox.exe" -no-remote -profile "%~dp0profile" --remote-debugging-port=9222
