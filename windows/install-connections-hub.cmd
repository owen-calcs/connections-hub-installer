@echo off
title Connections Hub installer
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-connections-hub.ps1" %*
echo.
pause
