#!/usr/bin/env bash
# ==============================================================================
# SFTP-HA 雙實體機部署腳本 - Node 1 (Master 節點)
# 適用作業系統: Rocky Linux 8 / 9 (x86_64)
# ==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   SFTPGo 企業高可用叢集 - Node 1 (Primary / Master) 自動安裝程式   ${NC}"
echo -e "${CYAN}=================================================================${NC}"

# 1. 權限檢查
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[錯誤] 請使用 root 權限或 sudo 執行此腳本！${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 2. 自動偵測環境
DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -n1)
DEFAULT_LOCAL_IP=$(ip -4 addr show dev "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "\n${YELLOW}>>> [步驟 1/6] 網路拓撲與節點設定 (請按 Enter 接受預設值)${NC}"

read -rp "請輸入 Node 1 本機網卡介面名稱 [預設: $DEFAULT_IFACE]: " IFACE
IFACE="${IFACE:-$DEFAULT_IFACE}"

read -rp "請輸入 Node 1 本機實體 IP [預設: $DEFAULT_LOCAL_IP]: " NODE1_IP
NODE1_IP="${NODE1_IP:-$DEFAULT_LOCAL_IP}"

read -rp "請輸入 Node 2 對向實體機 IP (必填): " NODE2_IP
while [ -z "$NODE2_IP" ]; do
  read -rp "${RED}Node 2 IP 不能為空，請輸入: ${NC}" NODE2_IP
done

read -rp "請輸入 DMZ 虛擬漂移 IP (VIP) 包含子網遮罩 [例如 192.168.10.100/24]: " VIP_CIDR
while [ -z "$VIP_CIDR" ]; do
  read -rp "${RED}VIP 遮罩不能為空，請輸入: ${NC}" VIP_CIDR
done

read -rp "請輸入 VRRP Virtual Router ID [預設: 51]: " VRID
VRID="${VRID:-51}"

# 自動生成 12 碼預設安全密碼
AUTO_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 || echo "SecP@ssw0rd2026")

echo -e "\n${YELLOW}>>> [步驟 2/6] 安全密鑰與帳號設定 (直接按 Enter 可採用安全隨機密碼)${NC}"

read -rp "請輸入 VRRP 心跳驗證密碼 [預設: SFTP_VRRP_PASS]: " VRRP_PASS
VRRP_PASS="${VRRP_PASS:-SFTP_VRRP_PASS}"

read -rp "請輸入 PostgreSQL sftpgo 資料庫密碼 [預設: 自動隨機產生]: " PG_PASS
PG_PASS="${PG_PASS:-$AUTO_PASS}"

read -rp "請輸入 PostgreSQL replicator 串流複寫密碼 [預設: 自動隨機產生]: " PG_REP_PASS
PG_REP_PASS="${PG_REP_PASS:-${AUTO_PASS}_rep}"

read -rp "請輸入 MinIO 根管理者帳號 [預設: minioadmin]: " MINIO_USER
MINIO_USER="${MINIO_USER:-minioadmin}"

read -rp "請輸入 MinIO 根管理者密碼 [預設: 自動隨機產生]: " MINIO_PASS
MINIO_PASS="${MINIO_PASS:-${AUTO_PASS}_mno}"

read -rp "請輸入 SFTPGo 管理者帳號 [預設: admin]: " SFTPGO_USER
SFTPGO_USER="${SFTPGO_USER:-admin}"

read -rp "請輸入 SFTPGo 管理者密碼 [預設: 自動隨機產生]: " SFTPGO_PASS
SFTPGO_PASS="${SFTPGO_PASS:-${AUTO_PASS}_sftp}"

# 3. 系統核心與依賴安裝
echo -e "\n${YELLOW}>>> [步驟 3/6] 檢查並安裝 Docker CE 與系統依賴...${NC}"
if ! command -v docker &> /dev/null; then
  echo -e "正在安裝 Docker CE 與 Docker Compose Plugin..."
  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
else
  echo -e "${GREEN}Docker 已安裝，啟動服務中...${NC}"
  systemctl enable --now docker
fi

# 核心參數調優 (允許綁定未持有的 VIP)
sysctl -w net.ipv4.ip_nonlocal_bind=1 > /dev/null
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-sftp-ha.conf

# 4. 防火牆放行
echo -e "\n${YELLOW}>>> [步驟 4/6] 配置 Firewalld 防火牆規則...${NC}"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=2222/tcp --permanent  # SFTP VIP
  firewall-cmd --add-port=8081/tcp --permanent  # WebAdmin VIP
  firewall-cmd --add-port=8404/tcp --permanent  # HAProxy Stats
  firewall-cmd --add-port=5432/tcp --permanent  # PostgreSQL Primary
  firewall-cmd --add-port=9000-9001/tcp --permanent # MinIO API / Console
  firewall-cmd --add-port=2022/tcp --permanent  # SFTP Backend
  firewall-cmd --add-port=8080/tcp --permanent  # Web Backend
  firewall-cmd --add-protocol=vrrp --permanent  # VRRP
  firewall-cmd --reload
  echo -e "${GREEN}防火牆埠號與 VRRP 協定放行完成。${NC}"
fi

# 5. 生成 .env 與組態檔案
echo -e "\n${YELLOW}>>> [步驟 5/6] 產生環境設定檔與動態組態...${NC}"

cat <<EOF > .env
NODE1_IP=$NODE1_IP
NODE2_IP=$NODE2_IP
VIP_CIDR=$VIP_CIDR
POSTGRES_USER=sftpgo
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=sftpgo
POSTGRES_REPLICATOR_PASSWORD=$PG_REP_PASS
MINIO_ROOT_USER=$MINIO_USER
MINIO_ROOT_PASSWORD=$MINIO_PASS
SFTPGO_ADMIN_USER=$SFTPGO_USER
SFTPGO_ADMIN_PASSWORD=$SFTPGO_PASS
EOF
chmod 600 .env

# 動態渲染 HAProxy 與 Keepalived 設定檔
sed "s/__NODE1_IP__/$NODE1_IP/g; s/__NODE2_IP__/$NODE2_IP/g" \
  config/haproxy/haproxy.cfg.template > config/haproxy/haproxy.cfg

sed "s/__IFACE__/$IFACE/g; s/__VRID__/$VRID/g; s/__AUTH_PASS__/$VRRP_PASS/g; s|__VIP_CIDR__|$VIP_CIDR|g" \
  config/keepalived/keepalived.conf.template > config/keepalived/keepalived.conf
chmod 644 config/keepalived/keepalived.conf

# 6. 拉起容器叢集
echo -e "\n${YELLOW}>>> [步驟 6/6] 啟動 Node 1 容器群集...${NC}"
docker compose pull
docker compose up -d

echo -e "等待服務初始化 (約 15 秒)..."
sleep 15

# 初始化本地 MinIO
echo -e "初始化 MinIO 本地儲存桶..."
chmod +x config/minio/setup-minio.sh
docker run --rm --network host -v "$SCRIPT_DIR/config/minio/setup-minio.sh:/setup.sh" \
  -e REMOTE_MINIO_HOST="$NODE2_IP" \
  -e MINIO_ROOT_USER="$MINIO_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_PASS" \
  cgr.dev/chainguard/minio:latest /bin/sh /setup.sh || true

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}       🎉 Node 1 (Master) 已成功建置並啟動完畢！                ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "VIP 狀態: $VIP_CIDR (正由本機優先承接)"
echo -e "SFTP 服務入口: sftp://[VIP]:2222 或 sftp://$NODE1_IP:2222"
echo -e "管理後台:      http://$NODE1_IP:8081 (帳號: $SFTPGO_USER / 密碼: $SFTPGO_PASS)"
echo -e "叢集監控儀表板: http://$NODE1_IP:8404"
echo -e "MinIO 控制台:  http://$NODE1_IP:9001 (帳號: $MINIO_USER / 密碼: $MINIO_PASS)"
echo -e "${YELLOW}請記下上述密碼，並將以下密碼配置於 Node 2 的安裝中：${NC}"
echo -e "  - PG Replicator 密碼: $PG_REP_PASS"
echo -e "  - MinIO Root 密碼:    $MINIO_PASS"
