@echo off
REM PS5 Buddy - one-click installer. Double-click this file.
REM No admin needed: PS5Upload and PS5 Buddy install for your user only.
title PS5 Buddy Installer
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\install.ps1"
echo.
pause
