# 企業級高可用 SFTPGo 系統備份與災難復原 (DR) 規劃報告

## 一、 執行摘要與設計目標

本報告針對現有之 **SFTPGo 企業級高可用雙節點叢集**（整合 Keepalived + HAProxy + SFTPGo Active-Active + MinIO S3 分散式儲存 + PostgreSQL 串流複寫）量身規劃實作可落地的全方位備份與災難復原架構。

### 1.1 核心防護原則
* **HA ≠ 備份**：雙節點高可用（HA）僅防範「單一硬體/節點非預期離線」，但無法防範「人員手滑誤刪、惡意軟體/勒索加密、邏輯改壞、跨機房全區斷電」。
* **3-2-1-1 備份原則**：
  * **3** 份資料複本（正式機 A、備援機 B、獨立備份主機）。
  * **2** 種不同儲存介質（正式叢集高速 SSD + 備份主機獨立儲存池/NAS）。
  * **1** 份異地/隔離副本（獨立備份機房或冷備儲存）。
  * **1** 份**不可變備份（Immutable Backup / WORM）**：防範勒索軟體覆寫或內部人員提權竄改。

### 1.2 服務水準目標 (SLA)
| 指標 | 目標值 | 說明 |
| :--- | :--- | :--- |
| **RPO (復原點目標)** | **< 1 小時** (檔案) / **< 15 分鐘** (DB) | 發生災難時，最多容忍損失的資料時間跨度。 |
| **RTO (復原時間目標)** | **< 30 分鐘** (全站滅頂重建) | 從全新伺服器開機到完全恢復 SFTP 服務對外營運的時間。 |
| **商務衝擊防護** | **零告警無縫復原** | 復原後外部客戶端（WinSCP、銀行批次排程）**不跳出 SSH Key 變更警告**。 |

---

## 二、 備份資產清單與策略矩陣

```
┌────────────────────────────────────────────────────────────────────────┐
│                        正式環境 SFTPGo HA 叢集                         │
├─────────────────┬─────────────────┬──────────────────┬─────────────────┤
│ ① MinIO 物件   │ ② PostgreSQL DB │ ③ SSH Host Keys  │ ④ 組態與密鑰    │
│ (S3 使用者檔案) │ (帳號/權限/映射)│ (主機識別金鑰)   │ (HAProxy/KP/.env│
└────────┬────────┴────────┬────────┴────────┬─────────┴────────┬────────┘
         │                 │                 │                  │
         │ (mc mirror)     │ (pg_dump)       │ (tar.gz)         │ (tar.gz)
         ▼                 ▼                 ▼                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│               【獨立備份主機】 (Pull 架構 / 防勒索唯讀隔離)            │
│  - 7 天日備份 (Daily)   - 4 週週備份 (Weekly)   - 12 個月月備 (Monthly)│
└────────────────────────────────────────────────────────────────────────┘
```

| 資產分類 | 具體路徑 / 來源 | 備份頻率 | 備份方式 | 關鍵目的 |
| :--- | :--- | :--- | :--- | :--- |
| **① 實體檔案 (MinIO S3)** | MinIO Bucket (`sftp-data`) | 每日 02:00 (增量) / 即時非同步複寫 | `mc mirror --overwrite` | 防止客戶上傳/存放之重要業務檔案遺失。 |
| **② 帳號與策略 (PostgreSQL)** | PostgreSQL `sftpgo` 資料庫 | 每日 01:00 / 03:00 (全備) | `docker exec pg_dump -Fc` | 保留使用者清單、密碼雜湊、S3路徑映射、配額、IP白名單。 |
| **③ 主機指紋 (SSH Host Keys)** | `/var/lib/sftpgo/id_*` | 變更時 / 每日隨組態打包 | `tar -czf hostkeys.tar.gz` | **極關鍵：避免全站重建後外部客戶端彈出「中間人攻擊」警告中斷批次連線。** |
| **④ 邊界網路與編排組態** | `config/`、`docker-compose.yml` | 變更時 / 每日打包 | Git 典藏 + 備份主機複寫 | 快速拉起 HAProxy、Keepalived VIP 與容器拓撲。 |
| **⑤ 環境變數與加密密鑰** | `.env`、Secretbox 金鑰 | 變更時 (極機密保存) | GPG 加密後異地備份 | 確保還原時 DB 密碼、S3 Access Key 與內部加密一致。 |
| **⑥ 傳輸與防護日誌** | 容器日誌 stdout / Defender | 每小時串流 / 每日輪替 | Vector / Docker 日誌轉存 | 法規遵循（ISO 27001、GDPR）、資安事件鑑識與防賴帳舉證。 |

---

## 三、 安全防護架構：防勒索與「拉取（Pull）」模式

> [!CAUTION]
> **傳統推送 (Push) 備份的致命風險**：
> 若在正式機寫腳本透過 SSH 連線並將檔案 `scp` 或 `rsync` 到備份主機，正式機勢必儲存登入備份機的憑證。一旦正式機被駭客攻陷或遭受勒索軟體加密，攻擊者會利用該憑證登入備份機，將所有備份一網打盡！

### 落地解決方案：由「備份主機」發動 Pull 作業
```
[正式機叢集 (PROD)]               [獨立備份主機 (BACKUP-SERVER)]
┌──────────────────┐               ┌───────────────────────────────┐
│ • MinIO API      │ <──────Pull── │ 1. 執行 mc mirror 拉取 S3 物件 │
│ • SSH (僅限唯讀) │ <──────Pull── │ 2. SSH 執行唯讀 dump 並拉取   │
│ (無備份機存取權) │               │ 3. 設定 WORM (chattr +i) 鎖定 │
└──────────────────┘               └───────────────────────────────┘
```
1. **單向存取原則**：正式機「完全不知道備份機的 IP 與帳密」，正式機上無任何登入備份機的私鑰。
2. **最小權限原則**：備份機使用專屬唯讀帳號（PostgreSQL 唯讀帳號、MinIO 唯讀 Policy）拉取資料。
3. **不可變備份 (WORM / Immutable)**：備份寫入備份伺服器後，利用 Linux `chattr +i`（或 S3 Object Lock）鎖定 7 天，即便 Root 也無法立即刪除或竄改。

---

## 四、 實作落地指南：自動化備份腳本清單

在**【獨立備份主機】**建立自動化維運目錄：
```
/opt/sftp-backup/
├── scripts/
│   ├── backup-db-and-configs.sh    # 資料庫、金鑰、設定檔拉取
│   ├── backup-minio-storage.sh     # MinIO 檔案增量鏡像
│   └── enforce-retention.sh        # 保留週期輪替與過期刪除
├── data/
│   ├── db/                         # PostgreSQL 備份檔 (*.dump)
│   ├── configs/                    # Host Keys 與組態檔 (*.tar.gz)
│   ├── storage/                    # MinIO 鏡像複本
│   └── logs/                       # 備份執行歷程記錄
└── sftp-backup.env                 # 連線參數與金鑰設定
```

### 4.1 腳本一：資料庫、SSH Host Keys 與組態備份 (`backup-db-and-configs.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# 載入環境變數
source /opt/sftp-backup/sftp-backup.env

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DATE_DAY=$(date +"%Y%m%d")
LOG_FILE="/opt/sftp-backup/data/logs/backup_${DATE_DAY}.log"
BACKUP_DB_DIR="/opt/sftp-backup/data/db"
BACKUP_CFG_DIR="/opt/sftp-backup/data/configs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "================== 開始執行 DB & 組態備份作業 =================="

# 1. 透過 SSH 呼叫正式機 primary 執行 pg_dump (自定義壓縮格式 -Fc)
log ">>> [1/3] 正在由 PostgreSQL 導出 sftpgo 資料庫..."
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "docker exec pg-primary pg_dump -U sftpgo -d sftpgo -F c -b -v" > "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump"

DB_SIZE=$(du -h "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump" | cut -f1)
log ">>> 資料庫備份成功！檔案大小: ${DB_SIZE}"

# 2. 拉取 SFTPGo 節點中的 SSH Host Keys (關鍵指紋資產)
log ">>> [2/3] 正在拉取 SFTPGo SSH Host Keys..."
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "docker run --rm -v sftp-ha-lab_sftpgo-a-data:/v alpine tar -cz -C /v id_rsa id_rsa.pub id_ed25519 id_ed25519.pub id_ecdsa id_ecdsa.pub" \
  > "${BACKUP_CFG_DIR}/sftpgo_hostkeys_${TIMESTAMP}.tar.gz"

# 3. 拉取 HAProxy, Keepalived, Docker Compose 設定檔
log ">>> [3/3] 正在拉取叢集組態檔案..."
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "tar -cz -C ${PROD_PROJECT_PATH} docker-compose.yml config/" \
  > "${BACKUP_CFG_DIR}/cluster_configs_${TIMESTAMP}.tar.gz"

# 產生 SHA256 校驗碼
sha256sum "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump" > "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump.sha256"

log "================== DB & 組態備份作業順利完成 =================="
```

---

### 4.2 腳本二：MinIO S3 實體檔案增量鏡像 (`backup-minio-storage.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

source /opt/sftp-backup/sftp-backup.env
LOG_FILE="/opt/sftp-backup/data/logs/backup_minio_$(date +'%Y%m%d').log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "================== 開始執行 MinIO S3 增量同步作業 =================="

# 設定 MinIO Client (mc) 連線別名
mc alias set prod-s3 "${PROD_MINIO_ENDPOINT}" "${PROD_MINIO_ACCESS_KEY}" "${PROD_MINIO_SECRET_KEY}" --api S3v4 > /dev/null

TARGET_DIR="/opt/sftp-backup/data/storage/sftp-bucket-mirror"
mkdir -p "${TARGET_DIR}"

# 執行增量鏡像同步
# 備註：故意不使用 --remove，以防止正式機檔案若遭受誤刪或勒索加密時，備份端不會立即同步刪除舊檔
log ">>> 正在進行 S3 Bucket 增量同步..."
mc mirror --overwrite prod-s3/sftp-data "${TARGET_DIR}/" | tee -a "${LOG_FILE}"

log ">>> MinIO S3 同步完成。目前儲存體總容量:"
du -sh "${TARGET_DIR}" | tee -a "${LOG_FILE}"
log "================== MinIO S3 同步作業結束 =================="
```

---

### 4.3 腳本三：保留週期輪替與防勒索鎖定 (`enforce-retention.sh`)

```bash
#!/usr/bin/env bash
# 保留策略：
# - 最近 7 天的每日備份 (Daily) 完整保留
# - 最近 4 週的每週日備份 (Weekly) 保留
# - 最近 12 個月的每月 1 號備份 (Monthly) 保留
# - 365 天以前的舊檔自動封存或清除

BACKUP_DB_DIR="/opt/sftp-backup/data/db"
BACKUP_CFG_DIR="/opt/sftp-backup/data/configs"

# 清理 7 天以上且不是週日(Day 0)的日備份
find "${BACKUP_DB_DIR}" -type f -name "*.dump" -mtime +7 | while read -r file; do
    file_date=$(stat -c %y "$file" | cut -d' ' -f1)
    day_of_week=$(date -d "$file_date" +%u)
    day_of_month=$(date -d "$file_date" +%d)

    # 如果既不是週日 (7)，也不是每月 1 號 (01)，則刪除
    if [ "$day_of_week" -ne 7 ] && [ "$day_of_month" -ne "01" ]; then
        rm -f "$file" "$file.sha256"
    fi
done

# 清理 30 天以上且不是每月 1 號的週備份
find "${BACKUP_DB_DIR}" -type f -name "*.dump" -mtime +30 | while read -r file; do
    file_date=$(stat -c %y "$file" | cut -d' ' -f1)
    day_of_month=$(date -d "$file_date" +%d)
    if [ "$day_of_month" -ne "01" ]; then
        rm -f "$file" "$file.sha256"
    fi
done

# 清理超過 365 天的所有舊備份
find "${BACKUP_DB_DIR}" -type f -name "*.dump" -mtime +365 -delete
find "${BACKUP_CFG_DIR}" -type f -name "*.tar.gz" -mtime +365 -delete
```

---

### 4.4 備份主機 Crontab 排程設定範例

在備份主機上的 `crontab -e` 加入：
```cron
# 每日凌晨 01:30 執行資料庫、SSH Host Keys 與組態備份
30 1 * * * /opt/sftp-backup/scripts/backup-db-and-configs.sh >> /opt/sftp-backup/data/logs/cron.log 2>&1

# 每日凌晨 02:30 執行 MinIO S3 實體檔案增量鏡像
30 2 * * * /opt/sftp-backup/scripts/backup-minio-storage.sh >> /opt/sftp-backup/data/logs/cron.log 2>&1

# 每日凌晨 04:00 執行過期備份清理與保留週期輪替
00 4 * * * /opt/sftp-backup/scripts/enforce-retention.sh >> /opt/sftp-backup/data/logs/cron.log 2>&1
```

---

## 五、 災難復原標準作業程序 (DR Runbook / SOP)

> [!IMPORTANT]
> **災難復原核心黃金律則**：
> 1. **先還原實體檔案 (MinIO)**
> 2. **再還原組態與金鑰 (Host Keys / Configs)**
> 3. **接著還原資料庫 (PostgreSQL)**
> 4. **最後才啟動 SFTPGo 服務節點**
> 
> *若順序顛倒（先開 SFTPGo 再放檔案），SFTPGo 初始化時會發現後端 S3 空白，可能引發配額重新計算錯誤或發出虛假的檔案遺失告警。*

### 演練情境：正式機房全毀，於新環境全新復原

#### 步驟 1：新主機環境初始化
在新機器（或 DR 備援機）安裝 Docker 與 Docker Compose：
```bash
# 建立專案目錄
mkdir -p /opt/sftp-ha-lab
cd /opt/sftp-ha-lab
```

#### 步驟 2：還原組態檔案與 SSH 主機金鑰
```bash
# 1. 解壓縮組態檔 (docker-compose.yml, config/)
tar -xzf /backup-source/cluster_configs_latest.tar.gz -C /opt/sftp-ha-lab/

# 2. 建立 SFTPGo 專屬 Volume 並還原 Host Keys
docker volume create sftp-ha-lab_sftpgo-a-data
docker volume create sftp-ha-lab_sftpgo-b-data

# 還原 Host Keys 至兩個節點（保證指紋完全不變！）
docker run --rm -v sftp-ha-lab_sftpgo-a-data:/v -v /backup-source:/b alpine tar -xzf /b/sftpgo_hostkeys_latest.tar.gz -C /v
docker run --rm -v sftp-ha-lab_sftpgo-b-data:/v -v /backup-source:/b alpine tar -xzf /b/sftpgo_hostkeys_latest.tar.gz -C /v
```

#### 步驟 3：啟動並還原 MinIO S3 實體檔案
```bash
# 1. 僅啟動 MinIO 服務節點
docker compose up -d minio-a minio-b

# 2. 等待 MinIO 健康檢查通過
sleep 10

# 3. 透過 mc mirror 將備份檔案全數灌回 MinIO
mc alias set dr-minio http://localhost:9001 minioadmin minioadminpassword
mc mb --ignore-existing dr-minio/sftp-data
mc mirror /backup-source/sftp-bucket-mirror/ dr-minio/sftp-data/
```

#### 步驟 4：啟動並還原 PostgreSQL 資料庫
```bash
# 1. 啟動 PostgreSQL 主要節點
docker compose up -d pg-primary

# 2. 透過 pg_restore 將 dump 檔還原
docker cp /backup-source/sftpgo_db_latest.dump pg-primary:/tmp/db.dump
docker exec pg-primary pg_restore -U sftpgo -d sftpgo --clean --if-exists -v /tmp/db.dump
docker exec pg-primary rm /tmp/db.dump

# 3. 啟動從節點進行同步
docker compose up -d pg-standby
```

#### 步驟 5：啟動前端入口與 SFTPGo 節點
```bash
# 啟動負載平衡、VIP 與 SFTPGo 運算節點
docker compose up -d sftpgo-a sftpgo-b sftp-vip-gateway keepalived-master keepalived-backup
```

#### 步驟 6：自動化健康檢查與驗證
直接執行專案內附的容錯與壓力測試腳本，驗證全功能正常：
```powershell
# 執行驗證 (可直接於維運機執行本 Lab 現有的測試工具)
.\test-ha-failover.ps1          # 驗證 VIP 與多節點連線
.\test-100mb-benchmark.ps1      # 驗證 S3 寫入與大檔傳輸能力
```

---

## 六、 監控、告警與驗證考核機制

1. **Zabbix 備份狀態主動監控**：
   * 在備份主機安裝 `zabbix-agent2`。
   * 配置 Item 監控：
     * `vfs.file.time[/opt/sftp-backup/data/db/sftpgo_db_latest.dump,modify]`：若超過 26 小時未更新，觸發「**嚴重告警：SFTP 資料庫備份中斷**」。
     * `vfs.file.size[/opt/sftp-backup/data/db/sftpgo_db_latest.dump]`：若備份檔大小低於 1MB（可能 dump 出空檔），觸發告警。
2. **季定期「無痛還原演練」制度**：
   * 「未經驗證的備份，視同沒有備份。」
   * 建議每一季由 IT 維運人員在獨立的隔離測試環境中，執行一次從備份檔進行的【自動化拉起還原測試】，確保備份檔沒有損毀、密碼未過期、還原 SOP 隨時保持最新有效。
