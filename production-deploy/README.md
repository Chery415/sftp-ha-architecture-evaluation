# SFTP-HA DMZ 雙實體機 Rocky Linux 部署專用包

本目錄專門為**企業正式環境 (DMZ 區域) 兩台全新 Rocky Linux 實體主機**所設計，提供高度自動化、防呆且低人工干預的安裝建置套件。

---

## 快速目錄導覽

```
production-deploy/
├── README.md                                          # 本導覽說明文件
├── docs/
│   └── RockyLinux_雙實體機_SFTP_HA_安裝部署手冊.md         # 完整落地 SOP 操作手冊 (強烈建議工程師先閱讀)
├── node1-master/                                      # 【實體機 1 (Node 1 / Master)】部署包
│   ├── deploy-node1.sh                                # 一鍵自動化安裝腳本 (含環境/防火牆/互動引導)
│   ├── docker-compose.yml                             # Node 1 容器編排檔
│   └── config/                                        # 組態設定模板 (HAProxy, Keepalived, PG, MinIO)
├── node2-backup/                                      # 【實體機 2 (Node 2 / Backup)】部署包
│   ├── deploy-node2.sh                                # 一鍵自動化安裝腳本 (含環境/從庫同步/雙向複寫)
│   ├── docker-compose.yml                             # Node 2 容器編排檔
│   └── config/                                        # 組態設定模板
└── tools/
    ├── verify-ha-cluster.sh                           # 雙機健康巡檢工具
    └── test-failover-drill.sh                         # 故障移轉模擬演練工具
```

---

## 三分鐘快速部署指引

### 步驟 1：部署第一台主機 (Node 1 - Master)
1. 將 `node1-master` 與 `tools` 資料夾複製到 Node 1 伺服器的 `/opt/`。
2. 執行自動化安裝腳本：
   ```bash
   cd /opt/node1-master
   chmod +x deploy-node1.sh
   ./deploy-node1.sh
   ```
3. 依提示確認 IP 與設定密碼（或按 Enter 使用安全隨機密碼，並記下生成的密碼）。

### 步驟 2：部署第二台主機 (Node 2 - Backup)
1. 將 `node2-backup` 與 `tools` 資料夾複製到 Node 2 伺服器的 `/opt/`。
2. 執行自動化安裝腳本：
   ```bash
   cd /opt/node2-backup
   chmod +x deploy-node2.sh
   ./deploy-node2.sh
   ```
3. 依提示輸入 Node 1 IP 以及在步驟 1 記下的對應密碼。

### 步驟 3：驗證雙機狀態
在任一主機執行狀態巡檢：
```bash
/opt/tools/verify-ha-cluster.sh
```
開啟瀏覽器檢查 HA 狀態：`http://[VIP]:8404` 或 `http://[Node1-IP]:8404`。
