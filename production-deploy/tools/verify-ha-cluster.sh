#!/usr/bin/env bash
# ==============================================================================
# SFTP-HA 雙實體機狀態巡檢與驗證工具
# ==============================================================================
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}       SFTP-HA 雙實體機 叢集狀態健康巡檢工具                      ${NC}"
echo -e "${CYAN}=================================================================${NC}"

# 1. 檢查 VIP 漂移與綁定狀態
echo -e "\n${YELLOW}[1] 檢查本機 VIP 綁定狀態:${NC}"
VIP_INFO=$(ip -4 addr show | grep ":vip" || true)
if [ -n "$VIP_INFO" ]; then
  echo -e "${GREEN}>>> 本機目前正持有 VIP: ${VIP_INFO}${NC}"
else
  echo -e ">>> 本機目前為備援狀態 (未持有 VIP，由對向節點持有)。"
fi

# 2. 檢查本機容器運行狀態
echo -e "\n${YELLOW}[2] 本機 Docker 容器健康狀態:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 3. 檢查資料庫複寫狀態
echo -e "\n${YELLOW}[3] 檢查 PostgreSQL 複寫狀態:${NC}"
if docker ps --format '{{.Names}}' | grep -q "sftp-postgres-primary"; then
  echo -e ">>> 本機為 PostgreSQL Primary，查詢連線中的 Standby 節點:"
  docker exec sftp-postgres-primary psql -U sftpgo -d sftpgo -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" || true
elif docker ps --format '{{.Names}}' | grep -q "sftp-postgres-standby"; then
  echo -e ">>> 本機為 PostgreSQL Standby，檢查是否處於 Standby 模式:"
  docker exec sftp-postgres-standby psql -U sftpgo -d sftpgo -c "SELECT pg_is_in_recovery() AS is_standby;" || true
fi

# 4. 檢查 HAProxy 儀表板
echo -e "\n${YELLOW}[4] 檢查 HAProxy 監聽狀態 (埠 2222, 8081, 8404):${NC}"
ss -tulpn | grep -E "2222|8081|8404" || netstat -tulpn | grep -E "2222|8081|8404" || true

echo -e "\n${GREEN}>>> 巡檢完成。詳細即時連線負載請開啟瀏覽器瀏覽: http://localhost:8404${NC}"
