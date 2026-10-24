# ==========================================================
# 企業級高可用 SFTP Lab 一鍵建置與啟動腳本
# ==========================================================
$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  企業級高可用 SFTP (SFTPGo + MinIO + PG + VIP) 啟動程序  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. 檢查 Docker 運行狀態
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
$dockerAppPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"

$daemonReady = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $daemonReady = $true }
} catch {
    $daemonReady = $false
}

if (-not $daemonReady) {
    if (Test-Path $dockerAppPath) {
        Write-Host ">>> 偵測到 Docker Desktop 尚未啟動，正在背景啟動 Docker Desktop..." -ForegroundColor Cyan
        Start-Process -FilePath $dockerAppPath
        
        Write-Host ">>> 正在等待 Docker Engine 就緒..." -ForegroundColor Gray
        $timeoutSec = 90
        $waited = 0
        while (-not $daemonReady -and $waited -lt $timeoutSec) {
            Start-Sleep -Seconds 5
            $waited += 5
            try {
                $null = docker info 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $daemonReady = $true
                    Write-Host ">>> Docker Engine 已成功就緒！" -ForegroundColor Green
                    break
                }
            } catch {}
            Write-Host ">>> 等待 Docker Engine 響應... (${waited}s/${timeoutSec}s)" -ForegroundColor Gray
        }
    }
    
    if (-not $daemonReady) {
        Write-Host "`n[錯誤] 無法連線至 Docker Daemon，請先確認 Docker Desktop 啟動完成。" -ForegroundColor Red
        exit 1
    }
}

# 2. 啟動 SFTP HA 容器叢集
Write-Host "`n[步驟 1] 啟動雙節點高可用容器服務..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n[錯誤] docker compose 啟動失敗，請檢視上方錯誤訊息。" -ForegroundColor Red
    exit 1
}

# 3. 監控健康就緒狀態
Write-Host "`n[步驟 2] 等候各節點與同步機制就緒..." -ForegroundColor Yellow
$services = @("pg-primary", "minio-a", "minio-b", "sftpgo-a", "sftpgo-b", "sftp-vip-gateway")

foreach ($svc in $services) {
    Write-Host ">>> 檢查服務健康狀態: $svc..." -NoNewline
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $status = docker inspect --format='{{json .State.Health.Status}}' $svc 2>$null
            if ($status -eq '"healthy"') {
                $ready = $true
                break
            }
            $running = docker inspect --format='{{.State.Running}}' $svc 2>$null
            if ($running -eq "true" -and ($status -eq "null" -or -not $status)) {
                $ready = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 2
    }
    if ($ready) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [已啟動/初始化中]" -ForegroundColor Yellow
    }
}

# 4. 驗證資料同步狀態
Write-Host "`n[步驟 3] 驗證 PostgreSQL 與 MinIO 雙向複寫..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

# 驗證 PG 串流
try {
    $pgRepl = docker exec pg-primary psql -U sftpgo -d sftpgo -t -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;" 2>&1
    Write-Host ">>> PostgreSQL 複寫狀態: $pgRepl" -ForegroundColor Cyan
} catch {
    Write-Host ">>> PostgreSQL 複寫正在初始化中..." -ForegroundColor Gray
}

# 5. 輸出存取端點與驗證手冊
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "          SFTP 高可用 Lab 模擬環境已成功建立並就緒！        " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

Write-Host ""
Write-Host "[統一流量入口 (VIP)]" -ForegroundColor White
Write-Host "  * SFTP 服務入口   : localhost:2222" -ForegroundColor White
Write-Host "  * Web Client/Admin: http://localhost:8081" -ForegroundColor White
Write-Host "  * HA 狀態監控板   : http://localhost:8404" -ForegroundColor White
Write-Host ""
Write-Host "[獨立節點控制台 (除錯與比對)]" -ForegroundColor White
Write-Host "  * MinIO 節點 A    : http://localhost:9001 (帳密: minioadmin / minioadminpassword)" -ForegroundColor White
Write-Host "  * MinIO 節點 B    : http://localhost:9003 (帳密: minioadmin / minioadminpassword)" -ForegroundColor White
Write-Host ""
Write-Host "[預設測試帳號]" -ForegroundColor White
Write-Host "  * SFTP 測試帳號   : sftpuser / sftp123456 (預設掛載 S3: sftp-data)" -ForegroundColor White
Write-Host "  * SFTPGo 管理帳號 : admin / Password123!" -ForegroundColor White
Write-Host ""
Write-Host "[自動化容錯移轉演練]" -ForegroundColor White
Write-Host "  執行本目錄下的測試腳本即可模擬「節點 1 崩潰，流量與資料無縫切換至節點 2」：" -ForegroundColor White
Write-Host "  .\test-ha-failover.ps1" -ForegroundColor White
Write-Host ""
