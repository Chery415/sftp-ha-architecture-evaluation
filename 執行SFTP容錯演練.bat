@echo off
chcp 65001 >nul
title 執行 SFTP 高可用容錯移轉與資料同步演練
cd /d "%~dp0\sftp-ha-lab"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\test-ha-failover.ps1"
echo.
pause
