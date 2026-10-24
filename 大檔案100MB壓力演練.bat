@echo off
chcp 65001 >nul
title 執行 SFTP 高可用 100MB 大檔案壓力傳輸與複寫自癒演練
cd /d "%~dp0\sftp-ha-lab"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\test-100mb-benchmark.ps1"
echo.
pause
