@echo off
chcp 65001 >nul
title 啟動 企業級高可用 SFTP Lab
cd /d "%~dp0\sftp-ha-lab"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\start-sftp-lab.ps1"
echo.
pause
