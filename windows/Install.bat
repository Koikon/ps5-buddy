@echo off
REM PS5 Buddy - one-click installer. Double-click this file.
title PS5 Buddy Installer
cd /d "%~dp0"

REM Re-launch as administrator if needed (Tailscale install needs it)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Asking for administrator permission...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\install.ps1"
echo.
pause
