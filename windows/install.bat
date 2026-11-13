@echo off
rem Double-click to install OSPOS on this Windows computer.
rem Options (run from a Command Prompt):  install.bat -InstallDir D:\OSPOS -Port 8080
rem                                         install.bat -DownloadOnly   (prepare an offline copy)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ospos.ps1" %*
echo.
pause
