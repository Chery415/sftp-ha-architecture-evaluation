# 企業級高可用 SFTPGo 系統備份與災難復原 (DR) 規劃報告

> **文件版本**：v2.0（正式環境落地版）  
> **適用架構**：Keepalived + HAProxy + SFTPGo (Active-Active) + MinIO S3 + PostgreSQL HA  
> **編制目的**：針對產線環境規劃整體備份架構、備份主機規格配置、防勒索安全機制與災難復原 (DR) 標準作業程序。

---

## 報告導讀與章節結構
為了維持高階決策報告的簡潔性與可讀性，本規劃書採用**「主文聚焦架構策略，技術細節拆分附件」**的設計：
* **第一章至第五章（主要報告）**：核心防護目標、備份資產清單、**備份主機規格與容量規劃**、四步災難復原標準程序。
* **附件 A（技術原理與觀念解析）**：`mc mirror`、`pg_dump`、`tar.gz` 深度原理說明與選型原因。
* **附件 B（自動化維運腳本庫）**：可直接佈署至備份主機的自動化 Pull 備份與清理腳本。
* **附件 C（災難復原快速指令對照表）**：極限災難時供工程師快速查閱之還原指令清單。

---

## 一、 核心防護原則與服務水準目標 (SLA)

### 1.1 核心防禦哲學
* **「HA 高可用 ≠ 備份」**：
  雙節點主備（Active-Active / Active-Standby）僅能防禦「單一伺服器硬體故障」，容錯切換以秒計；若遭遇**人員誤刪、惡意程式/勒索加密、邏輯改壞**，高可用機制會將錯誤在數秒內同步至另一節點。獨立離線的備份主機是企業最後的生存防線。
* **落實 3-2-1-1 防勒索備份原則**：
  * **3** 份資料副本（正式機 A、備援機 B、獨立備份主機）。
  * **2** 種不同儲存介質（正式叢集高速 SSD 陣列 + 備份主機獨立儲存池）。
  * **1** 份異地/冷儲存副本（實體隔離機房或獨立雲端儲存槽）。
  * **1** 份**不可變備份 (WORM / Immutable)**：檔案寫入後鎖定，任何帳號（含 Root）在保留期內皆無法篡改或刪除。

### 1.2 服務水準目標 (SLA)
| 關鍵指標 | 目標值 | 業務衝擊與意義 |
| :--- | :--- | :--- |
| **RPO (復原點目標)** | **< 1 小時** (檔案) / **< 15 分鐘** (DB) | 系統發生災難時，最多容忍損失的資料時間跨度。 |
| **RTO (復原時間目標)** | **< 30 分鐘** (全站滅頂重建) | 從全新空機開機到完全恢復 SFTP 服務對外營運的時間。 |
| **商務無感指標** | **零告警無縫復原** | 復原後外部客戶（銀行、供應商排程）**不跳出 SSH Key 變更警告**。 |

---

## 二、 備份資產清單與策略矩陣

整套 SFTPGo 系統的所有資產，依其資料特性被歸納為三大備份組別：

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

| 組別 | 項目名稱 | 儲存位置 | 備份頻率 | 推薦工具與格式 | 關鍵防護目的 |
| :---: | :--- | :--- | :---: | :---: | :--- |
| **A** | **使用者實體檔案** | MinIO Bucket (`sftp-data`) | 每日凌晨 (增量) / 即時 | `mc mirror` (檔案鏡像) | 保存所有客戶上傳、存放之實體業務檔案。 |
| **B** | **帳號策略資料庫** | PostgreSQL (`sftpgo` DB) | 每日凌晨 (全備) | `pg_dump -Fc` (二進位自訂) | 保存帳號密碼雜湊、S3路徑映射、目錄權限與配額。 |
| **C** | **主機指紋與金鑰** | `/var/lib/sftpgo/id_*` | 變更時 / 每日隨組態 | `tar.gz` (封存 Linux 權限) | **極關鍵：避免全站重建後客戶端跳出「中間人攻擊」警告。** |
| **C** | **網路邊界組態** | HAProxy / Keepalived / `.env` | 變更時 (Git/每日) | `tar.gz` (機密加密保存) | 1 分鐘內快速重現 VIP、負載平衡與連線密碼。 |

---

## 三、 專用備份主機（Backup Host）規劃做法

很多維運規劃的誤區是認為「備份 MinIO 就必須再架一套 MinIO；備份 PostgreSQL 就必須再裝一套資料庫」。本規劃採用**輕量化解耦架構**，備份主機僅需扮演「安全檔案庫與任務調度者」。

### 3.1 備份主機硬體與軟體規格建議
* **作業系統**：標準 Linux（Ubuntu 22.04 LTS / Rocky Linux 9 / RHEL 9 皆可）。
* **運算資源**：低負載（建議配置 4 核心 CPU、8GB ~ 16GB RAM）。
* **網路頻寬**：具備 1Gbps ~ 10Gbps 內部局域網路，確保夜間大量資料同步不塞車。
* **軟體需求**：
  * **不需要安裝**：PostgreSQL Server、Docker 引擎、MinIO Server。
  * **僅需安裝**：`mc`（MinIO Client 單一執行檔）、`openssh-client`、`cron`，以及選配之 `postgresql-client`（用於預覽 dump 內容）。

### 3.2 儲存容量預估與磁碟配置
備份主機儲存空間分為三大分區：
1. **MinIO 物件鏡像區**：配置正式環境儲存量的 **1.2 ~ 1.5 倍**（因不刪除過期誤刪檔，預留歷史緩衝空間）。
2. **PostgreSQL DB 備份區**：配置 **20GB ~ 50GB**（單次 dump 僅數十 MB，自定義格式壓縮率極高，足夠保存一整年歷史備份）。
3. **組態與金鑰區**：小於 **1GB**（`tar.gz` 打包後單檔僅數十 KB）。
* **磁碟保護建議**：採用硬體 RAID 1 或 RAID 5/6 陣列，避免備份主機本身因單顆硬碟損壞而失效。

### 3.3 安全防禦架構（防勒索與權限最小化）
1. **單向「拉取 (Pull)」機制**：
   * 正式機上**嚴禁存放登入備份機的 SSH Key 或密碼**。
   * 由備份主機透過專用排程，使用**唯讀帳號**主動向正式機拉取資料。即便正式機全區遭駭客控制，攻擊者也無法逆向存取備份主機。
2. **存取權限嚴格隔離**：
   * 備份目錄執行權限封鎖：`chmod 700 /backup/sftp-configs`，僅限 `root` 或專用 `backup-runner` 帳號存取，嚴防 `.env` 密鑰外流。
3. **不可變備份 (WORM 鎖定)**：
   * 備份寫入後，系統腳本自動執行 `chattr +i` 將歷史封存檔鎖定 7 天。

---

## 四、 災難復原黃金律則 (DR SOP)

當遭遇最嚴重的全站毀滅事件（例如硬體全損，在新主機全新部署）時，請務必恪守以下**標準四步復原順序**：

```
[步驟 1: 先灌實體檔案] ──> [步驟 2: 注入金鑰與組態] ──> [步驟 3: 還原資料庫] ──> [步驟 4: 啟動運算服務]
 (MinIO S3 檔案就緒)       (SSH Host Keys 600)       (帳號與權限映射復原)     (SFTPGo/HAProxy 上線)
```

> [!IMPORTANT]
> **為什麼順序不能顛倒？**
> 若先啟動 SFTPGo 才放檔案，SFTPGo 啟動時掃描 S3 會發現是空目錄，可能導致使用者容量配額計算異常或觸發遺失告警。先讓「實體檔案」與「資料庫」就緒，最後拉起 SFTPGo，服務即可在秒級內平穩接管。

1. **第一步（檔案還原）**：啟動新 MinIO 容器，在備份主機執行 `mc mirror` 反向同步，將本地目錄檔案全數灌回新 S3 Bucket。
2. **第二步（指紋還原）**：將備份的 `sftpgo_hostkeys.tar.gz` 倒回 Docker Volume，確保主機指紋不變且維持 `chmod 600`。
3. **第三步（大腦還原）**：啟動 PostgreSQL，執行 `pg_restore -d sftpgo`，瞬間還原所有帳號、密碼雜湊與 S3 映射。
4. **第四步（服務上線）**：啟動 `sftpgo-a`、`sftpgo-b` 與 HAProxy / Keepalived，執行自動化驗證腳本確認對外服務。

---

## 五、 維運排程與健全度監控

### 5.1 備份排程規劃
* **01:30**：執行資料庫 `pg_dump`、SSH Host Keys 與組態打包（產生 SHA256 校驗碼）。
* **02:30**：執行 MinIO S3 物件增量鏡像同步（離峰時間傳輸）。
* **04:00**：執行過期備份清理與保留週期輪替（7天日備、4週週備、12月月備）。

### 5.2 整合現有 Zabbix 監控告警
* **備份檔新鮮度監控**：Zabbix 監控備份目錄檔案修改時間，若超過 26 小時未產生新備份，立即觸發 High 告警。
* **備份檔大小異常監控**：監控 `.dump` 檔案大小，若小於 1MB（可能 dump 失敗產出空檔），觸發嚴重警告。
* **每季定期無痛還原演練**：每季在隔離測試環境執行一次自動化拉起還原，驗證備份檔可讀性。

---

## 附件 A：關鍵技術原理與深度解析 (Glossary & Deep Dive)

### A.1 `mc mirror` 深度解析
* **它是什麼？**
  `mc` 是 MinIO 官方命令列管理工具（MinIO Client），`mc mirror` 則是物件儲存世界的 `rsync`。
* **運作原理**：
  它會自動比對來源端與目的端的物件名稱、檔案大小、最後修改時間與 ETag 校驗碼，**僅傳輸新增或異動過的檔案**。
* **為什麼備份端不需要裝 MinIO？**
  `mc mirror` 具備雙重轉換能力，它可以直接將遠端的 S3 物件儲存桶「原樣轉譯」成一般作業系統上的普通檔案與目錄結構。備份主機上的檔案直接用一般的 `ls` 或檔案總管就能開啟檢閱。

### A.2 `pg_dump` 深度解析
* **它是什麼？**
  PostgreSQL 官方原生邏輯備份工具。它透過建立單一交易唯讀快照（Snapshot Isolation），在**完全不中斷產線線上交易**的前提下，將資料表結構與資料列導出。
* **為什麼指名採用自訂二進位格式 (`-F c`)？**
  `pg_dump` 支援純文字 (`.sql`) 與二進位自訂格式 (`-F c`)。自訂格式內建壓縮索引，不僅檔案體積極小，更能在災後透過 `pg_restore` 啟用多執行緒（並行加速）還原，甚至能選擇性只還原特定使用者或資料表。

### A.3 `tar.gz` 深度解析
* **它是什麼？**
  `tar`（Tape Archive）負責將多個零碎檔案封裝保留目錄樹狀結構；`gz`（gzip）則負責進行資料壓縮。
* **為什麼不用普通 ZIP？**
  SSH 私鑰（如 `id_rsa`）在 Linux 安全規範下**強制要求 600 權限（唯獨擁有者可讀寫）**。若使用普通 zip 備份，Linux 檔案權限會遺失變為開放的 `777` 或 `644`，災後 SFTPGo 會判定金鑰不安全而直接拒絕啟動。`tar.gz` 能 100% 封存 Linux 原生權限與 UID/GID，確保解壓縮即開箱可用。

---

## 附件 B：自動化維運腳本庫 (Scripts Library)

以下三支腳本部署於**【備份主機】**的 `/opt/sftp-backup/scripts/` 目錄：

### B.1 資料庫與金鑰組態備份腳本 (`backup-db-and-configs.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

source /opt/sftp-backup/sftp-backup.env
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DB_DIR="/opt/sftp-backup/data/db"
BACKUP_CFG_DIR="/opt/sftp-backup/data/configs"

# 1. SSH 呼叫正式機 PostgreSQL 執行 pg_dump
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "docker exec pg-primary pg_dump -U sftpgo -d sftpgo -F c -b -v" > "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump"

# 2. 封裝 SSH Host Keys (保持 600 權限)
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "docker run --rm -v sftp-ha-lab_sftpgo-a-data:/v alpine tar -cz -C /v id_rsa id_rsa.pub id_ed25519 id_ed25519.pub id_ecdsa id_ecdsa.pub" \
  > "${BACKUP_CFG_DIR}/sftpgo_hostkeys_${TIMESTAMP}.tar.gz"

# 3. 打包叢集組態檔與環境變數
ssh -i "${PROD_SSH_KEY}" -p "${PROD_SSH_PORT}" "${PROD_SSH_USER}@${PROD_HOST}" \
  "tar -cz -C ${PROD_PROJECT_PATH} docker-compose.yml config/ .env" \
  > "${BACKUP_CFG_DIR}/cluster_configs_${TIMESTAMP}.tar.gz"

# 4. 生成 SHA256 校驗碼
sha256sum "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump" > "${BACKUP_DB_DIR}/sftpgo_db_${TIMESTAMP}.dump.sha256"
```

### B.2 MinIO S3 實體檔案增量鏡像腳本 (`backup-minio-storage.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

source /opt/sftp-backup/sftp-backup.env
TARGET_DIR="/opt/sftp-backup/data/storage/sftp-bucket-mirror"
mkdir -p "${TARGET_DIR}"

# 設定 MinIO Client 連線別名
mc alias set prod-s3 "${PROD_MINIO_ENDPOINT}" "${PROD_MINIO_ACCESS_KEY}" "${PROD_MINIO_SECRET_KEY}" --api S3v4 > /dev/null

# 執行增量鏡像 (不加 --remove 以保留正式機誤刪之歷史緩衝)
mc mirror --overwrite prod-s3/sftp-data "${TARGET_DIR}/"
```

### B.3 保留週期輪替清理腳本 (`enforce-retention.sh`)
```bash
#!/usr/bin/env bash
BACKUP_DB_DIR="/opt/sftp-backup/data/db"
BACKUP_CFG_DIR="/opt/sftp-backup/data/configs"

# 刪除 7 天以上且非每週日、非每月 1 號的日備份
find "${BACKUP_DB_DIR}" -type f -name "*.dump" -mtime +7 | while read -r file; do
    file_date=$(stat -c %y "$file" | cut -d' ' -f1)
    day_of_week=$(date -d "$file_date" +%u)
    day_of_month=$(date -d "$file_date" +%d)
    if [ "$day_of_week" -ne 7 ] && [ "$day_of_month" -ne "01" ]; then
        rm -f "$file" "$file.sha256"
    fi
done

# 刪除 365 天以前的所有過期歷史檔
find "${BACKUP_DB_DIR}" -type f -name "*.dump" -mtime +365 -delete
find "${BACKUP_CFG_DIR}" -type f -name "*.tar.gz" -mtime +365 -delete
```

---

## 附件 C：災難重建快速操作手冊 (DR Fast Recovery Runbook)

當在全新機器進行緊急災難重建時，工程師可直接依序執行下列指令：

```bash
# 【步驟 1：建立專案目錄並解壓縮組態】
mkdir -p /opt/sftp-ha-lab && cd /opt/sftp-ha-lab
tar -xzf /backup-path/cluster_configs_latest.tar.gz -C /opt/sftp-ha-lab/

# 【步驟 2：原樣還原 SSH Host Keys 至 Docker Volume】
docker volume create sftp-ha-lab_sftpgo-a-data
docker volume create sftp-ha-lab_sftpgo-b-data
docker run --rm -v sftp-ha-lab_sftpgo-a-data:/v -v /backup-path:/b alpine tar -xzf /b/sftpgo_hostkeys_latest.tar.gz -C /v
docker run --rm -v sftp-ha-lab_sftpgo-b-data:/v -v /backup-path:/b alpine tar -xzf /b/sftpgo_hostkeys_latest.tar.gz -C /v

# 【步驟 3：啟動 MinIO 並將 S3 檔案反向灌回】
docker compose up -d minio-a minio-b
sleep 10
mc alias set dr-minio http://localhost:9001 minioadmin minioadminpassword
mc mb --ignore-existing dr-minio/sftp-data
mc mirror --overwrite /backup-path/sftp-bucket-mirror/ dr-minio/sftp-data/

# 【步驟 4：啟動 PostgreSQL 並匯入資料庫】
docker compose up -d pg-primary
docker cp /backup-path/sftpgo_db_latest.dump pg-primary:/tmp/db.dump
docker exec pg-primary pg_restore -U sftpgo -d sftpgo --clean --if-exists -v /tmp/db.dump
docker exec pg-primary rm /tmp/db.dump
docker compose up -d pg-standby

# 【步驟 5：啟動前端入口與 SFTPGo 運算節點】
docker compose up -d sftpgo-a sftpgo-b sftp-vip-gateway keepalived-master keepalived-backup
```
