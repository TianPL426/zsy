@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File run_autoplot.ps1
pause
