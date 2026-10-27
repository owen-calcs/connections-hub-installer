@echo off
title Calcs MCP installer
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-calcs-mcp.ps1" %*
echo.
pause
