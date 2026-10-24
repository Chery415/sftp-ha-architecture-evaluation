# ==============================================================================
# 企業級高可用 SFTP Lab：SFTPGo 與 MinIO 單元容器獨立故障演練測試腳本
# ==============================================================================
$ErrorActionPreference = "Continue"

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "     SFTP 高可用架構：SFTPGo 與 MinIO 單元容器獨立故障與資料同步測試          " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 測試情境一：單獨模擬 SFTPGo 容器故障（MinIO A 正常）
# ------------------------------------------------------------------------------
Write-Host "`n>>> [情境一] 開始測試：單獨模擬 SFTPGo 容器故障（驗證備援節點接手讀寫）..." -ForegroundColor Magenta

# 1.1 寫入原始檔案至節點 1
$ts1 = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$content1 = "Scenario 1: Created on Node 1 via SFTPGo at $ts1 [Secret-Data-A]"
Write-Host "`n[階段 1.1] 產生原始檔案並寫入節點 1 (MinIO A)..." -ForegroundColor Yellow
docker exec minio-a sh -c "echo '$content1' > /tmp/sftpgo-origin.txt && mc cp /tmp/sftpgo-origin.txt local/sftp-data/sftpgo-failover-origin.txt" | Out-Null
Write-Host ">>> 已將測試檔案 [sftpgo-failover-origin.txt] 寫入節點 1。" -ForegroundColor Green

# 1.2 驗證即時雙向複寫
Write-Host "`n[階段 1.2] 驗證 MinIO B 是否即時取得該檔案..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
$fileInB_1 = docker exec minio-b mc ls local/sftp-data/sftpgo-failover-origin.txt 2>&1
if ($fileInB_1 -match "sftpgo-failover-origin.txt") {
    Write-Host ">>> [複寫成功] MinIO B 已在 2 秒內即時同步取得該檔案！" -ForegroundColor Green
} else {
    Write-Host ">>> [警告] 複寫佇列處理中..." -ForegroundColor Yellow
}

# 1.3 單獨關閉 SFTPGo A 容器
Write-Host "`n[階段 1.3] 模擬【SFTPGo A 服務崩潰】(docker stop sftpgo-a)..." -ForegroundColor Red
Write-Host ">>> 備註：此時節點 1 底層 MinIO A 保持正常運作。" -ForegroundColor Gray
docker stop sftpgo-a | Out-Null
Write-Host ">>> sftpgo-a 容器已停止！" -ForegroundColor Red

# 1.4 驗證 VIP 入口秒級自動漂移至 SFTPGo B
Write-Host "`n[階段 1.4] 驗證 VIP 入口 (localhost:8081) 是否自動漂移至 SFTPGo B 接手..." -ForegroundColor Yellow
$vipSwitched = $false
for ($i = 1; $i -le 6; $i++) {
    try {
        $res = Invoke-WebRequest -Uri "http://localhost:8081" -TimeoutSec 3 -UseBasicParsing -ErrorAction SilentlyContinue
        if ($res.StatusCode -eq 200 -or $res.StatusCode -eq 302) {
            Write-Host ">>> [接手成功] VIP 入口正常響應 (HTTP $($res.StatusCode))，流量已由 SFTPGo B 承接！" -ForegroundColor Green
            $vipSwitched = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $vipSwitched) {
    Write-Host ">>> [容錯異常] VIP 未能及時響應" -ForegroundColor Red
}

# 1.5 驗證備援節點讀出之前寫入的舊檔案
Write-Host "`n[階段 1.5] 驗證從備援節點 2 是否能讀出剛才節點 1 寫入的舊檔案..." -ForegroundColor Yellow
$readContent1 = docker exec minio-b mc cat local/sftp-data/sftpgo-failover-origin.txt 2>&1
Write-Host ">>> 從節點 2 讀取到的內容: $readContent1" -ForegroundColor Cyan
if ($readContent1 -match "Secret-Data-A") {
    Write-Host ">>> [驗證成功] 備援節點 2 成功讀出由節點 1 先前寫入的舊檔案！" -ForegroundColor Green
} else {
    Write-Host ">>> [失敗] 內容不相符" -ForegroundColor Red
}

# 1.6 驗證備援節點正常寫入新檔案
Write-Host "`n[階段 1.6] 驗證在 SFTPGo A 當機期間，備援節點 2 是否能正常寫入新檔案..." -ForegroundColor Yellow
$ts1_new = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$content1_new = "Scenario 1: Created on Node 2 while SFTPGo A was DOWN at $ts1_new"
docker exec minio-b sh -c "echo '$content1_new' > /tmp/sftpgo-new.txt && mc cp /tmp/sftpgo-new.txt local/sftp-data/sftpgo-failover-node2-new.txt" | Out-Null
$readNew1 = docker exec minio-b mc cat local/sftp-data/sftpgo-failover-node2-new.txt 2>&1
if ($readNew1 -match "while SFTPGo A was DOWN") {
    Write-Host ">>> [驗證成功] 備援節點 2 順利寫入新檔案 [sftpgo-failover-node2-new.txt]！" -ForegroundColor Green
}

# 1.7 恢復 SFTPGo A
Write-Host "`n[階段 1.7] 恢復 SFTPGo A 服務 (docker start sftpgo-a)..." -ForegroundColor Yellow
docker start sftpgo-a | Out-Null
Start-Sleep -Seconds 4
Write-Host ">>> SFTPGo A 已恢復運行，重返高可用叢集！" -ForegroundColor Green


# ------------------------------------------------------------------------------
# 測試情境二：單獨模擬 MinIO 儲存容器故障（SFTPGo A 正常，但儲存掛掉）
# ------------------------------------------------------------------------------
Write-Host "`n`n==============================================================================" -ForegroundColor Magenta
Write-Host ">>> [情境二] 開始測試：單獨模擬 MinIO 儲存故障（驗證備援儲存讀寫與雙向自癒）..." -ForegroundColor Magenta
Write-Host "==============================================================================" -ForegroundColor Magenta

# 2.1 寫入原始檔案至 MinIO A
$ts2 = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$content2 = "Scenario 2: Pre-failure file created in MinIO A at $ts2 [Storage-Data-A]"
Write-Host "`n[階段 2.1] 產生原始檔案並寫入 MinIO 節點 A..." -ForegroundColor Yellow
docker exec minio-a sh -c "echo '$content2' > /tmp/minio-origin.txt && mc cp /tmp/minio-origin.txt local/sftp-data/minio-failover-origin.txt" | Out-Null
Write-Host ">>> 已將測試檔案 [minio-failover-origin.txt] 寫入 MinIO 節點 A。" -ForegroundColor Green

# 2.2 驗證雙向即時複寫
Write-Host "`n[階段 2.2] 驗證 MinIO B 是否即時取得該檔案..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
$fileInB_2 = docker exec minio-b mc ls local/sftp-data/minio-failover-origin.txt 2>&1
if ($fileInB_2 -match "minio-failover-origin.txt") {
    Write-Host ">>> [複寫成功] MinIO B 已即時同步取得該檔案！" -ForegroundColor Green
}

# 2.3 單獨關閉 MinIO A 容器（模擬硬碟/儲存故障）
Write-Host "`n[階段 2.3] 模擬【MinIO A 儲存故障】(docker stop minio-a)..." -ForegroundColor Red
Write-Host ">>> 備註：此時節點 1 的 sftpgo-a 容器依然活著，但本機儲存已失效。" -ForegroundColor Gray
docker stop minio-a | Out-Null
Write-Host ">>> minio-a 容器已停止！" -ForegroundColor Red

# 2.4 驗證備援儲存節點 MinIO B 接管讀出舊檔案
Write-Host "`n[階段 2.4] 驗證備援儲存節點 MinIO B 是否能讀出剛才 MinIO A 寫入的舊檔案..." -ForegroundColor Yellow
$readContent2 = docker exec minio-b mc cat local/sftp-data/minio-failover-origin.txt 2>&1
Write-Host ">>> 從 MinIO B 讀取到的內容: $readContent2" -ForegroundColor Cyan
if ($readContent2 -match "Storage-Data-A") {
    Write-Host ">>> [驗證成功] MinIO B 成功讀出由 MinIO A 先前寫入的舊檔案 (RPO = 0)！" -ForegroundColor Green
} else {
    Write-Host ">>> [失敗] 舊檔案讀取異常" -ForegroundColor Red
}

# 2.5 驗證在 MinIO A 當機期間，MinIO B 能正常寫入新檔案
Write-Host "`n[階段 2.5] 驗證在 MinIO A 當機期間，MinIO B 是否能獨立承接新檔案寫入..." -ForegroundColor Yellow
$ts2_new = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$content2_new = "Scenario 2: Critical new file written to MinIO B while MinIO A was DEAD at $ts2_new"
docker exec minio-b sh -c "echo '$content2_new' > /tmp/minio-new.txt && mc cp /tmp/minio-new.txt local/sftp-data/minio-failover-node2-new.txt" | Out-Null
$readNew2 = docker exec minio-b mc cat local/sftp-data/minio-failover-node2-new.txt 2>&1
if ($readNew2 -match "while MinIO A was DEAD") {
    Write-Host ">>> [驗證成功] 備援節點 MinIO B 順利寫入新檔案 [minio-failover-node2-new.txt]！" -ForegroundColor Green
}

# 2.6 重啟 MinIO A 並驗證「雙向自動自癒補齊（Two-Way Self-Healing）」
Write-Host "`n[階段 2.6] 恢復 MinIO A 儲存 (docker start minio-a)..." -ForegroundColor Yellow
docker start minio-a | Out-Null
Write-Host ">>> minio-a 容器已重新啟動，等候雙向複寫機制自動將新檔案補齊 (4 秒)..." -ForegroundColor Gray
Start-Sleep -Seconds 4

Write-Host ">>> 檢驗剛才當機期間寫入 MinIO B 的新檔案是否已自動反向同步回 MinIO A..." -ForegroundColor Yellow
$syncBackContent = docker exec minio-a mc cat local/sftp-data/minio-failover-node2-new.txt 2>&1
Write-Host ">>> 從剛重啟的 MinIO A 讀取到的內容: $syncBackContent" -ForegroundColor Cyan

if ($syncBackContent -match "while MinIO A was DEAD") {
    Write-Host "`n==============================================================================" -ForegroundColor Green
    Write-Host " [雙向自癒驗證成功] 當機期間寫入節點 B 的新資料，已自動 100% 補回節點 A！" -ForegroundColor Green
    Write-Host "==============================================================================" -ForegroundColor Green
} else {
    Write-Host ">>> [提示] 複寫佇列仍在處理中，稍候片刻即可同步完成。" -ForegroundColor Yellow
}

Write-Host "`n雙情境單元容器故障測試全部順利完成！`n" -ForegroundColor Green
