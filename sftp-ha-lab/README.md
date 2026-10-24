# 企業級高可用 SFTP 容器化模擬環境 (SFTP HA Lab)

本專案完全還原《企業級高可用SFTP架構規劃書》中的「雙節點超融合高可用架構」，採用純 Docker Compose 容器編排實現，適合於個人筆記型電腦上進行零成本、低資源消耗的高可用 (HA) 與災難復原演練。

---

## 系統架構對應

```
┌────────────────────────────────────────────────────────┐
│                   1. 使用者存取層                      │
│   外部 Web Client  /  內部管理員  /  外部 SFTP 客戶端   │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│             2. 流量入口與故障移轉層 (VIP)              │
│     Keepalived VRRP (172.28.0.100) & HA VIP 入口       │
│     * SFTP: localhost:2222                             │
│     * Web:  localhost:8081                             │
└──────────────┬───────────────────────────┬─────────────┘
               │ (主線流量)                 │ (容錯移轉)
               ▼                           ▼
┌───────────────────────────────┐ ┌───────────────────────────────┐
│  3. 節點伺服器 1 (Master)     │ │  4. 節點伺服器 2 (Backup)     │
│  - Keepalived (主 - 權重 101) │ │  - Keepalived (備 - 權重 100) │
│  - Docker: SFTPGo (實例 A)    │ │  - Docker: SFTPGo (實例 B)    │
│  - Docker: MinIO S3 (節點 A)  │ │  - Docker: MinIO S3 (節點 B)  │
│  - Docker: PostgreSQL (主)    │ │  - Docker: PostgreSQL (從)    │
└──────────────┬────────────────┘ └──────────────┬────────────────┘
               │                                 │
               ├────── MinIO 原生雙向即時複本 ─────┤ (Active-Active 2-Way)
               │                                 │
               └────── PostgreSQL 串流複本 ──────┘ (Streaming Replication)
```

---

## 快速啟動

### 1. 一鍵啟動環境
於 PowerShell 執行：
```powershell
.\start-sftp-lab.ps1
```
腳本將自動：
* 檢查並啟動 Docker Desktop（若尚未啟動）。
* 啟動 8 個容器（PostgreSQL 主從、MinIO 雙節點、SFTPGo 雙實例、Keepalived 與 VIP Gateway）。
* 自動初始化 MinIO Bucket `sftp-data` 並設定雙向即時複寫。
* 自動建立預設管理員與 SFTP 測試帳號。

---

## 連線資訊與預設帳密

| 項目 | 連線端點 | 預設帳號 | 預設密碼 | 說明 |
| :--- | :--- | :--- | :--- | :--- |
| **統一 SFTP 入口 (VIP)** | `localhost:2222` | `sftpuser` | `sftp123456` | 外部 SFTP 客戶端使用 (FileZilla/WinSCP) |
| **統一 Web 入口 (VIP)** | `http://localhost:8081` | `admin` | `Password123!` | SFTPGo Web 管理台與網頁檔案總管 |
| **HA 狀態即時監控板** | `http://localhost:8404` | - | - | 檢視主備節點連線狀態與流量流向 |
| **MinIO 節點 A 控制台** | `http://localhost:9001` | `minioadmin` | `minioadminpassword` | 節點 1 儲存後台 |
| **MinIO 節點 B 控制台** | `http://localhost:9003` | `minioadmin` | `minioadminpassword` | 節點 2 儲存後台 |

---

## 容錯移轉與資料同步演練

直接執行專屬演練腳本：
```powershell
.\test-ha-failover.ps1
```

演練步驟說明：
1. **資料寫入**：將測試檔案寫入 MinIO 節點 A。
2. **即時複寫驗證**：確認節點 B 即時收到該檔案（RPO = 0）。
3. **模擬宕機**：自動停止節點 1 的 SFTPGo 與 MinIO 容器。
4. **容錯接管驗證**：驗證 VIP 入口在幾秒內無縫漂移至節點 2，服務持續響應。
5. **資料無損校驗**：從節點 2 讀取檔案並比對內容 Hash。
6. **故障修復重返**：重啟節點 1，自動重返高可用叢集。
