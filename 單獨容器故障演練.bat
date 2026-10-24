@echo off
chcp 65001 >nul
title 執行 SFTPGo 與 MinIO 單獨容器故障與資料讀寫演練
cd /d "%~dp0\sftp-ha-lab"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\test-component-failover.ps1"
echo.
pause
