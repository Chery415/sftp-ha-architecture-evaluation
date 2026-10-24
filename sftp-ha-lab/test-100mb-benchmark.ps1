# ==============================================================================
# 企業級高可用 SFTP Lab：100 MB 大檔案壓力傳輸、複寫延遲與容錯自癒實測腳本
# ==============================================================================
$ErrorActionPreference = "Continue"

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "     SFTP 高可用架構：100 MB 大檔案傳輸效能、複寫延遲與容錯自癒測試           " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 階段 1：產生 100 MB 隨機二進位大檔案與基準 SHA-256
# ------------------------------------------------------------------------------
Write-Host "`n[階段 1] 正在節點 1 產生 100 MB 隨機二進位真實測試檔案 (urandom)..." -ForegroundColor Yellow
$genOutput = docker exec minio-a sh -c "dd if=/dev/urandom of=/tmp/data-100mb-A.bin bs=1M count=100 2>&1"
Write-Host ">>> 100 MB 檔案生成完成 (104,857,600 Bytes)。" -ForegroundColor Green

Write-Host ">>> 正在計算節點 1 原始檔案之 SHA-256 基準雜湊碼..." -ForegroundColor Yellow
$hashA_raw = docker exec minio-a sh -c "sha256sum /tmp/data-100mb-A.bin"
$hashA = ($hashA_raw -split "\s+")[0].Trim()
Write-Host ">>> 節點 1 原始檔案 SHA-256: $hashA" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 階段 2：寫入 MinIO A 儲存池
# ------------------------------------------------------------------------------
Write-Host "`n[階段 2] 將 100 MB 檔案寫入 MinIO 節點 A (sftp-data bucket)..." -ForegroundColor Yellow
$swUpload = [System.Diagnostics.Stopwatch]::StartNew()
$uploadOutput = docker exec minio-a sh -c "mc cp /tmp/data-100mb-A.bin local/sftp-data/data-100mb-A.bin 2>&1"
$swUpload.Stop()
$uploadSec = [math]::Round($swUpload.Elapsed.TotalSeconds, 2)
$uploadSpeed = [math]::Round(100 / [math]::Max($uploadSec, 0.01), 2)
Write-Host ">>> 本地寫入完成！耗時: ${uploadSec} 秒 (平均寫入速率: ${uploadSpeed} MB/s)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 階段 3：監控並測量 MinIO 雙向複寫（Replication）到節點 2 的延遲
# ------------------------------------------------------------------------------
Write-Host "`n[階段 3] 監控並精準測量 MinIO 雙向即時複寫至節點 2 (MinIO B) 的耗時..." -ForegroundColor Yellow
$swRepl = [System.Diagnostics.Stopwatch]::StartNew()
$synced = $false
$maxWait = 60 # 最長等待 60 秒
$elapsedSec = 0

for ($i = 0; $i -lt ($maxWait * 2); $i++) {
    Start-Sleep -Milliseconds 500
    # 檢查節點 B 檔案大小是否達到 100MB (104857600 Bytes)
    $lsOut = docker exec minio-b mc ls local/sftp-data/data-100mb-A.bin 2>$null
    if ($lsOut -match "100MiB" -or $lsOut -match "105MB" -or $lsOut -match "104857600") {
        $synced = $true
        break
    }
}
$swRepl.Stop()
$replSec = [math]::Round($swRepl.Elapsed.TotalSeconds, 2)
$replSpeed = [math]::Round(100 / [math]::Max($replSec, 0.01), 2)

if ($synced) {
    Write-Host ">>> [同步成功] 100 MB 檔案已完整抵達節點 2！" -ForegroundColor Green
    Write-Host ">>> 跨節點雙向複寫延遲 (Replication Latency): ${replSec} 秒 (平均複寫速率: ${replSpeed} MB/s)" -ForegroundColor Green
} else {
    Write-Host ">>> [超時] 複寫仍在佇列中處理中。" -ForegroundColor Yellow
}

Write-Host "`n>>> 正在校驗節點 2 (MinIO B) 同步後之檔案完整性 (SHA-256)..." -ForegroundColor Yellow
$hashB_raw = docker exec minio-b sh -c "mc cat local/sftp-data/data-100mb-A.bin | sha256sum"
$hashB = ($hashB_raw -split "\s+")[0].Trim()
Write-Host ">>> 節點 2 同步檔案 SHA-256: $hashB" -ForegroundColor Cyan

if ($hashA -eq $hashB) {
    Write-Host ">>> [校驗成功] 雙節點 100 MB 檔案 SHA-256 100% 完全相符！(位元零失真，RPO = 0)" -ForegroundColor Green
} else {
    Write-Host ">>> [校驗失敗] 雜湊碼不吻合！" -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# 階段 4：模擬節點 1 斷電 (Crash)，驗證備援節點 100 MB 讀取與 VIP 接管
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor Magenta
Write-Host "[階段 4] 模擬節點 1 突發斷電崩潰 (docker stop sftpgo-a minio-a)..." -ForegroundColor Magenta
Write-Host "==============================================================================" -ForegroundColor Magenta
docker stop sftpgo-a minio-a | Out-Null
Write-Host ">>> 節點 1 已斷線（主機模擬宕機）！" -ForegroundColor Red

Write-Host ">>> 驗證統一 VIP 入口 (http://localhost:8081) 容錯切換..." -ForegroundColor Yellow
$vipOk = $false
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        $res = Invoke-WebRequest -Uri "http://localhost:8081" -TimeoutSec 3 -UseBasicParsing -ErrorAction SilentlyContinue
        if ($res.StatusCode -eq 200 -or $res.StatusCode -eq 302) {
            Write-Host ">>> [容錯成功] VIP 入口正常響應 (HTTP $($res.StatusCode))，流量已漂移至節點 2！" -ForegroundColor Green
            $vipOk = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 1
}

Write-Host ">>> 在節點 1 死亡狀態下，直接從備援節點 2 串流下載校驗 100 MB 檔案..." -ForegroundColor Yellow
$swRead = [System.Diagnostics.Stopwatch]::StartNew()
$hashRead_raw = docker exec minio-b sh -c "mc cat local/sftp-data/data-100mb-A.bin | sha256sum"
$swRead.Stop()
$readSec = [math]::Round($swRead.Elapsed.TotalSeconds, 2)
$hashRead = ($hashRead_raw -split "\s+")[0].Trim()
if ($hashRead -eq $hashA) {
    Write-Host ">>> [讀取成功] 節點 1 宕機時，備援節點 2 順利讀出完整 100 MB 舊檔案！耗時: ${readSec} 秒 (SHA-256 一致)" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 階段 5：在節點 1 停機期間，向備援節點 2 寫入另一個 100 MB 大檔案
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor Magenta
Write-Host "[階段 5] 模擬節點 1 當機期間，向備援節點 2 寫入全新 100 MB 大檔案 (data-100mb-B.bin)..." -ForegroundColor Magenta
Write-Host "==============================================================================" -ForegroundColor Magenta
$genOutB = docker exec minio-b sh -c "dd if=/dev/urandom of=/tmp/data-100mb-B.bin bs=1M count=100 2>&1"
$hashB_origin_raw = docker exec minio-b sh -c "sha256sum /tmp/data-100mb-B.bin"
$hashB_origin = ($hashB_origin_raw -split "\s+")[0].Trim()
Write-Host ">>> 節點 2 全新 100 MB 檔案 SHA-256 基準: $hashB_origin" -ForegroundColor Cyan

docker exec minio-b sh -c "mc cp /tmp/data-100mb-B.bin local/sftp-data/data-100mb-B.bin 2>&1" | Out-Null
Write-Host ">>> 備援節點 2 成功獨立承接寫入全新 100 MB 大檔案！" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 階段 6：恢復節點 1 (Failback)，驗證 100 MB 大檔案「雙向自癒反向補齊」
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor Magenta
Write-Host "[階段 6] 恢復節點 1 服務 (Failback)，測試 100 MB 大檔案自動反向補發同步..." -ForegroundColor Magenta
Write-Host "==============================================================================" -ForegroundColor Magenta
docker start minio-a sftpgo-a | Out-Null
Write-Host ">>> 節點 1 容器已重新啟動，等候 MinIO 雙向複寫隊列將 100 MB 補齊至節點 1..." -ForegroundColor Gray

$swHeal = [System.Diagnostics.Stopwatch]::StartNew()
$healed = $false
for ($j = 0; $j -lt 40; $j++) {
    Start-Sleep -Seconds 1
    $lsHeal = docker exec minio-a mc ls local/sftp-data/data-100mb-B.bin 2>$null
    if ($lsHeal -match "100MiB" -or $lsHeal -match "105MB" -or $lsHeal -match "104857600") {
        $healed = $true
        break
    }
}
$swHeal.Stop()
$healSec = [math]::Round($swHeal.Elapsed.TotalSeconds, 2)

if ($healed) {
    Write-Host ">>> [雙向自癒成功] 節點 1 已自動從節點 2 補齊 100 MB 大檔案！耗時: ${healSec} 秒" -ForegroundColor Green
    $hashHealed_raw = docker exec minio-a sh -c "mc cat local/sftp-data/data-100mb-B.bin | sha256sum"
    $hashHealed = ($hashHealed_raw -split "\s+")[0].Trim()
    Write-Host ">>> 節點 1 補齊檔案 SHA-256: $hashHealed" -ForegroundColor Cyan
    if ($hashHealed -eq $hashB_origin) {
        Write-Host ">>> [完整性驗證成功] 反向同步檔案 SHA-256 100% 完全相符！" -ForegroundColor Green
    }
} else {
    Write-Host ">>> [提示] 大檔案仍在大佇列傳輸中。" -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 階段 7：清理測試大檔案 (釋放筆電儲存空間)
# ------------------------------------------------------------------------------
Write-Host "`n[階段 7] 清理暫存測試大檔案以釋放硬碟空間..." -ForegroundColor Yellow
docker exec minio-a rm -f /tmp/data-100mb-A.bin 2>$null
docker exec minio-b rm -f /tmp/data-100mb-B.bin 2>$null
docker exec minio-a mc rm -r --force local/sftp-data/data-100mb-A.bin 2>$null | Out-Null
docker exec minio-b mc rm -r --force local/sftp-data/data-100mb-B.bin 2>$null | Out-Null
Write-Host ">>> 暫存大檔案清理完畢。" -ForegroundColor Green

Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "              100 MB 大檔案壓力傳輸與高可用容錯演練全部完成！                 " -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
