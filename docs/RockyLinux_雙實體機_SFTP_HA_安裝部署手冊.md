# Rocky Linux 雙實體機 SFTPGo 企業高可用叢集安裝部署手冊

> **文件版本**：v2.0 (DMZ 實體機落地專用)  
> **適用作業系統**：Rocky Linux 8.x / 9.x (x86_64)  
> **目標架構**：DMZ 雙實體伺服器 (Keepalived VIP + HAProxy + SFTPGo Active-Active + MinIO S3 雙向複寫 + PostgreSQL 串流複寫)

---

## 一、 架構拓撲與網路規劃

本架構部署於企業 DMZ 區域，由兩台獨立的 x86_64 實體伺服器組成，具備負載平衡、狀態即時同步與零秒差故障切換能力。

### 1.1 網路與 IP 配置範例規劃表

| 角色 / 服務 | 節點 1 (Node 1 / Master) | 節點 2 (Node 2 / Backup) | 備註說明 |
| :--- | :--- | :--- | :--- |
| **主機名稱 (Hostname)** | `sftp-dmz-node1` | `sftp-dmz-node2` | 實體機名稱 |
| **作業系統** | Rocky Linux 9 (x86_64) | Rocky Linux 9 (x86_64) | 乾淨安裝 (Minimal 即可) |
| **實體網卡介面** | `ens192` (或 `eth0`) | `ens192` (或 `eth0`) | 依實體主機實際網卡為準 |
| **實體實體 IP** | `192.168.10.11` | `192.168.10.12` | 實體機真實 IP |
| **虛擬漂移 VIP** | **`192.168.10.100/24`** | **`192.168.10.100/24`** | **對外/對內統一服務入口** |
| **VRRP Router ID** | `51` | `51` | 雙機必須一致 |

### 1.2 網路埠號與防火牆需求清單

兩台 Rocky Linux 伺服器的 `firewalld` 需要放行以下通訊埠號（自動安裝腳本會自動完成設定）：

| 埠號 (Port) | 協定 | 存取來源 | 用途說明 |
| :--- | :---: | :--- | :--- |
| **2222** | TCP | 網際網路 / 企業內網客戶端 | **SFTP 統一服務入口 (由 VIP 接收)** |
| **8081** | TCP | 企業內網 / 管理網段 | **SFTPGo Web 管理後台 / Web Client 統一入口** |
| **8404** | TCP | IT 維運 / 監控網段 | **HAProxy 負載平衡與叢集健康狀態儀表板** |
| **5432** | TCP | 雙機互聯 (Node 1 ⇄ Node 2) | PostgreSQL 交易串流複寫 |
| **9000** | TCP | 雙機互聯 (Node 1 ⇄ Node 2) | MinIO S3 API 物件雙向複寫 |
| **9001** | TCP | IT 維運網段 | MinIO S3 網頁控制台 (Console) |
| **2022** | TCP | 本機 / HAProxy 轉發 | SFTPGo 容器內部 SFTP 埠號 |
| **8080** | TCP | 本機 / HAProxy 轉發 | SFTPGo 容器內部 Web 埠號 |
| **VRRP (協定 112)**| IP Proto | 雙機互聯 (Node 1 ⇄ Node 2) | Keepalived 心跳廣播與 VIP 漂移協定 |

---

## 二、 部署前準備作業

### 2.1 實體機作業系統確認
1. 確認兩台伺服器均已安裝好 **Rocky Linux 8 或 9**。
2. 確認網路線插妥，兩台主機能夠互相 `ping` 通對方的實體 IP。
3. 建議將兩台主機時間設定為 NTP 自動同步（如 `chronyd`），避免資料庫串流複寫時戳落差。

### 2.2 下載/傳輸安裝檔案至伺服器
將本專案目錄中的 `production-deploy` 部署包複製到兩台實體機的 `/opt/` 目錄：
* **Node 1**：保留 `node1-master`、`tools` 目錄。
* **Node 2**：保留 `node2-backup`、`tools` 目錄。

---

## 三、 實體機 Node 1 (Master) 自動化安裝步驟

> 💡 **操作原則**：安裝順序為**「先安裝 Node 1，待其啟動完成後再安裝 Node 2」**。

### 步驟 1：登入 Node 1 並切換至安裝目錄
```bash
# 登入 Node 1
ssh root@192.168.10.11

# 切換至 Node 1 部署目錄
cd /opt/production-deploy/node1-master/

# 賦予安裝腳本執行權限
chmod +x deploy-node1.sh
```

### 步驟 2：執行一鍵自動化部署腳本
```bash
./deploy-node1.sh
```

### 步驟 3：依畫面提示輸入網路與密鑰參數
腳本執行過程中會進入**互動式設定**，讓工程師自主掌控密碼：
1. **網卡介面**：腳本會自動偵測預設網卡（如 `ens192`），確認無誤直接按 `Enter`。
2. **Node 1 本機 IP**：腳本自動偵測帶出，直接按 `Enter`。
3. **Node 2 對向 IP**：輸入預計分配給第二台主機的 IP（例如 `192.168.10.12`）。
4. **VIP 遮罩**：輸入 DMZ 虛擬漂移 IP（例如 `192.168.10.100/24`）。
5. **VRRP 路由器 ID**：預設為 `51`，直接按 `Enter`。
6. **各項帳號密碼**：
   * **PostgreSQL 密碼**：可手動輸入，或直接按 `Enter` 由系統生成高強度隨機密碼。
   * **Replicator 複寫密碼**：直接按 `Enter` 或自訂（**請記下此密碼，Node 2 需輸入相同密碼**）。
   * **MinIO 管理者密碼**：直接按 `Enter` 或自訂（**請記下此密碼，Node 2 需輸入相同密碼**）。
   * **SFTPGo 管理者密碼**：直接按 `Enter` 或自訂（用於登入 WebAdmin）。

### 步驟 4：自動執行項目（無須人工介入）
腳本將全自動依序完成：
* 自動配置 Rocky Linux `dnf` 源並安裝最新 Docker CE 與 Docker Compose Plugin。
* 自動調優 Linux 核心參數（`net.ipv4.ip_nonlocal_bind = 1`）。
* 自動配置 `firewalld` 放行 2222、8081、8404、5432、9000、VRRP 等通訊。
* 自動渲染生成 `haproxy.cfg` 與 `keepalived.conf`。
* 自動啟動容器並初始化本機 MinIO S3 儲存桶。

當看到綠色文字 **`🎉 Node 1 (Master) 已成功建置並啟動完畢！`** 即代表 Node 1 部署成功。

---

## 四、 實體機 Node 2 (Backup) 自動化安裝步驟

### 步驟 1：登入 Node 2 並切換至安裝目錄
```bash
# 登入 Node 2
ssh root@192.168.10.12

# 切換至 Node 2 部署目錄
cd /opt/production-deploy/node2-backup/

# 賦予安裝腳本執行權限
chmod +x deploy-node2.sh
```

### 步驟 2：執行一鍵自動化部署腳本
```bash
./deploy-node2.sh
```

### 步驟 3：依畫面提示輸入設定值
* **Node 2 本機 IP**：確認預設值按 `Enter`。
* **Node 1 Master IP**：輸入 Node 1 的 IP（`192.168.10.11`）。
* **VIP 遮罩**：輸入與 Node 1 相同之 VIP（`192.168.10.100/24`）。
* **各項連線密碼**：**請輸入在 Node 1 安裝時所產生的對應密碼**（PostgreSQL 密碼、Replicator 密碼、MinIO 密碼）。

### 步驟 4：自動同步與加入叢集
腳本將自動：
1. 自動完成 Docker 與防火牆環境設置。
2. 自動連線至 Node 1 PostgreSQL 進行 `pg_basebackup` 全庫拉取，自動啟動唯讀串流複寫。
3. 自動將本地 MinIO 與 Node 1 MinIO 串接，建立**雙向 S3 儲存桶鏡像複寫**。
4. 啟動 Keepalived Backup 節點，處於待命監控狀態。

當看到綠色文字 **`🎉 Node 2 (Backup) 已成功建置並加入 HA 叢集！`** 即代表雙機叢集建置大功告成！

---

## 五、 雙機高可用 (HA) 驗證與日常維運

### 5.1 狀態快速巡檢 (`verify-ha-cluster.sh`)
在任一台主機執行巡檢工具：
```bash
cd /opt/production-deploy/tools/
chmod +x verify-ha-cluster.sh
./verify-ha-cluster.sh
```
* **檢查 VIP 誰在持有**：正常情況下，Node 1 會顯示 `本機目前正持有 VIP`；Node 2 會顯示 `為備援狀態`。
* **檢查 PostgreSQL 複寫狀態**：
  在 Node 1 執行，會列出連線中的 Standby 節點 IP、狀態為 `streaming`、且 `replay_lag` 幾近為 0。

### 5.2 故障移轉 (Failover) 演練 (`test-failover-drill.sh`)
在目前持有 VIP 的 Node 1 上執行模擬演練：
```bash
cd /opt/production-deploy/tools/
chmod +x test-failover-drill.sh
./test-failover-drill.sh
```
1. 腳本會模擬關閉 Node 1 的 Keepalived 與 HAProxy。
2. 前往 Node 2 執行 `ip -4 addr show`，會發現 VIP（`192.168.10.100`）已在 **2 秒內瞬間漂移至 Node 2**！
3. 此時客戶端透過 `sftp://192.168.10.100:2222` 連線依然秒連成功，服務完全不中斷！
4. 10 秒後腳本自動重啟 Node 1 服務，VIP 依據 Priority 權重平順切回 Node 1。

### 5.3 網頁儀表板監控
* **HAProxy 即時連線狀態**：瀏覽 `http://192.168.10.100:8404`（或兩台實體 IP:8404），可查看兩台節點的連線分配比例與健康燈號。
* **SFTPGo 管理後台**：瀏覽 `http://192.168.10.100:8081` 進行帳號、配額與目錄權限維護。

---

## 六、 常見問題排除 (Troubleshooting)

### Q1：VIP 沒有漂移，兩台機器都各自綁定了 VIP（腦裂 Split-brain）？
* **原因**：VRRP 心跳廣播被防火牆或網路交換機（Switch）阻擋。
* **解法**：
  1. 確保已執行 `firewall-cmd --add-protocol=vrrp --permanent && firewall-cmd --reload`。
  2. 若在虛擬化環境（如 ESXi / Proxmox），請確保虛擬交換機開啟了 **Promiscuous Mode（混雜模式）** 與 **MAC Address Changes**。

### Q2：Node 2 的 PostgreSQL Standby 一直顯示連不上 Node 1？
* **原因**：Node 1 防火牆未開放 5432 埠，或密碼輸入不符。
* **解法**：
  在 Node 2 執行 `nc -zv 192.168.10.11 5432` 測試通訊。若通訊正常但認證失敗，請檢查 Node 2 的 `.env` 中的 `POSTGRES_REPLICATOR_PASSWORD` 是否與 Node 1 相同。

### Q3：如何手動重啟某個節點的所有服務？
* **重啟指令**：
  ```bash
  cd /opt/production-deploy/node1-master  # 或 node2-backup
  docker compose restart
  ```
