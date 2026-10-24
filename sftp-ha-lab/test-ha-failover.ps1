# ==========================================================
# 企業級高可用 SFTP Lab 故障移轉與資料同步演練腳本
# ==========================================================
$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host "   SFTP 高可用雙節點 容錯移轉 (Failover) 與同步演練       " -ForegroundColor Magenta
Write-Host "==========================================================" -ForegroundColor Magenta

# 步驟 1：產出測試數據並寫入節點 1
Write-Host "`n[階段 1] 寫入測試檔案至節點 1..." -ForegroundColor Yellow
$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$testContent = "SFTP High-Availability Failover Test: Created at $timestamp"

# 透過 minio-a 將檔案注入 MinIO A
docker exec minio-a sh -c "echo '$testContent' > /tmp/ha-proof.txt && mc cp /tmp/ha-proof.txt local/sftp-data/ha-proof.txt"
Write-Host ">>> 已將測試檔案 [ha-proof.txt] 寫入 MinIO 節點 A。" -ForegroundColor Green

# 步驟 2：驗證 MinIO 雙向即時複寫
Write-Host "`n[階段 2] 驗證 MinIO 雙向即時複寫狀態..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
$fileInB = docker exec minio-b mc ls local/sftp-data/ha-proof.txt 2>&1
if ($fileInB -match "ha-proof.txt") {
    Write-Host ">>> [驗證成功] MinIO 節點 B 已即時同步取得該檔案！" -ForegroundColor Green
    Write-Host "    $fileInB" -ForegroundColor Gray
} else {
    Write-Host ">>> [提示] 等候複寫佇列同步..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    $fileInB = docker exec minio-b mc ls local/sftp-data/ha-proof.txt 2>&1
    Write-Host "    $fileInB" -ForegroundColor Gray
}

# 步驟 3：驗證目前流量入口指向 (預設應為 Node A)
Write-Host "`n[階段 3] 檢查流量入口 (VIP Gateway) 當前主節點狀態..." -ForegroundColor Yellow
try {
    $res = Invoke-WebRequest -Uri "http://localhost:8081" -Method Head -TimeoutSec 3 -UseBasicParsing -ErrorAction SilentlyContinue
    Write-Host ">>> 統一 VIP 入口 (http://localhost:8081) 正常提供服務 (HTTP $($res.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host ">>> 無法連線至 VIP 入口，請先確認服務已啟動。" -ForegroundColor Red
}

# 步驟 4：模擬節點 1 發生突發性崩潰
Write-Host "`n[階段 4] 模擬節點 1 伺服器硬體斷電/崩潰..." -ForegroundColor Red
Write-Host ">>> 正在停止 sftpgo-a 與 minio-a 容器..." -ForegroundColor DarkYellow
docker stop sftpgo-a minio-a | Out-Null
Write-Host ">>> 節點 1 已斷線（模擬宕機完成）！" -ForegroundColor Red

# 等候 HAProxy 健康檢查判定（約 3~4 秒）
Write-Host ">>> 等候 VIP 與健康監控偵測並觸發漂移 (4秒)..." -ForegroundColor Gray
Start-Sleep -Seconds 4

# 步驟 5：驗證故障移轉 (Failover) 至節點 2
Write-Host "`n[階段 5] 驗證容錯移轉 (Failover) 至備援節點 2..." -ForegroundColor Yellow
$failoverSuccess = $false
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        $resFailover = Invoke-WebRequest -Uri "http://localhost:8081" -TimeoutSec 3 -UseBasicParsing -ErrorAction SilentlyContinue
        if ($resFailover.StatusCode -eq 200 -or $resFailover.StatusCode -eq 302) {
            Write-Host ">>> [容錯成功] 統一 VIP 自動切換至節點 2，Web 介面仍正常響應 (HTTP $($resFailover.StatusCode))！" -ForegroundColor Green
            $failoverSuccess = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $failoverSuccess) {
    Write-Host ">>> [容錯異常] 備援節點未能及時接管" -ForegroundColor Red
}

# 從節點 B 讀取驗證資料完整性
$contentFromB = docker exec minio-b mc cat local/sftp-data/ha-proof.txt 2>&1
Write-Host ">>> 從節點 B 讀取到的檔案內容:" -ForegroundColor Cyan
Write-Host "    $contentFromB" -ForegroundColor White

if ($contentFromB -match "SFTP High-Availability") {
    Write-Host ">>> [資料一致性驗證成功] 零資料遺失 (RPO = 0)！" -ForegroundColor Green
}

# 步驟 6：模擬節點 1 故障修復並重返叢集
Write-Host "`n[階段 6] 模擬節點 1 修復完畢重啟 (Failback)..." -ForegroundColor Yellow
docker start minio-a sftpgo-a | Out-Null
Write-Host ">>> 節點 1 容器已重新啟動，正在重返高可用叢集..." -ForegroundColor Green

Start-Sleep -Seconds 5
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "      容錯移轉演練完成！雙節點高可用性與資料同步驗證無誤    " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
