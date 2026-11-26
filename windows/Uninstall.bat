@echo off
title PS5 Buddy Uninstall
copy /y "%LOCALAPPDATA%\PS5Buddy\uninstall.ps1" "%TEMP%\ps5buddy-uninstall.ps1" >nul 2>nul || copy /y "%~dp0setup\uninstall.ps1" "%TEMP%\ps5buddy-uninstall.ps1" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\ps5buddy-uninstall.ps1" & echo. & pause
