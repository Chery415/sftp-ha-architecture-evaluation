#!/usr/bin/env bash
# ==============================================================================
# SFTP-HA 雙實體機 故障移轉 (Failover) 演練工具
# ==============================================================================
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}       SFTP-HA 雙實體機 容錯切換 (Failover) 模擬演練工具          ${NC}"
echo -e "${CYAN}=================================================================${NC}"

echo -e "${YELLOW}此腳本將模擬本機 Keepalived / HAProxy 服務中斷，以驗證 VIP 漂移至對向節點。${NC}"
read -rp "是否確定要執行故障切換演練？(y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "已取消演練。"
  exit 0
fi

echo -e "\n>>> [1/3] 當前 VIP 狀態:"
ip -4 addr show | grep ":vip" || echo "本機未持有 VIP"

echo -e "\n>>> [2/3] 模擬關閉本機 Keepalived 與 HAProxy..."
docker stop sftp-keepalived-1 sftp-haproxy-1 2>/dev/null || docker stop sftp-keepalived-2 sftp-haproxy-2 2>/dev/null || true

echo -e "${GREEN}>>> 本機服務已停止。請在對向實體機執行 ip addr 驗證 VIP 是否已在 2 秒內順利接手！${NC}"
echo -e "等待 10 秒後將自動恢復本機服務..."
sleep 10

echo -e "\n>>> [3/3] 恢復本機服務..."
docker start sftp-haproxy-1 sftp-keepalived-1 2>/dev/null || docker start sftp-haproxy-2 sftp-keepalived-2 2>/dev/null || true

echo -e "\n${GREEN}>>> 服務已恢復！檢查本機 VIP 現況:${NC}"
sleep 2
ip -4 addr show | grep ":vip" || echo "本機未持有 VIP (若對向為 Master 則屬正常)"
echo -e "${GREEN}=== 演練作業結束 ===${NC}"
