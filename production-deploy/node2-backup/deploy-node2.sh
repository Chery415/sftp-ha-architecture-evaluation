#!/usr/bin/env bash
# ==============================================================================
# SFTP-HA 雙實體機部署腳本 - Node 2 (Backup 節點)
# 適用作業系統: Rocky Linux 8 / 9 (x86_64)
# ==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}   SFTPGo 企業高可用叢集 - Node 2 (Secondary / Backup) 自動安裝程式 ${NC}"
echo -e "${CYAN}=================================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[錯誤] 請使用 root 權限或 sudo 執行此腳本！${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -n1)
DEFAULT_LOCAL_IP=$(ip -4 addr show dev "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "\n${YELLOW}>>> [步驟 1/6] 網路拓撲與節點設定 (請按 Enter 接受預設值)${NC}"

read -rp "請輸入 Node 2 本機網卡介面名稱 [預設: $DEFAULT_IFACE]: " IFACE
IFACE="${IFACE:-$DEFAULT_IFACE}"

read -rp "請輸入 Node 2 本機實體 IP [預設: $DEFAULT_LOCAL_IP]: " NODE2_IP
NODE2_IP="${NODE2_IP:-$DEFAULT_LOCAL_IP}"

read -rp "請輸入 Node 1 (Master) 實體機 IP (必填): " NODE1_IP
while [ -z "$NODE1_IP" ]; do
  read -rp "${RED}Node 1 IP 不能為空，請輸入: ${NC}" NODE1_IP
done

read -rp "請輸入 DMZ 虛擬漂移 IP (VIP) 包含子網遮罩 [例如 192.168.10.100/24]: " VIP_CIDR
while [ -z "$VIP_CIDR" ]; do
  read -rp "${RED}VIP 遮罩不能為空，請輸入: ${NC}" VIP_CIDR
done

read -rp "請輸入 VRRP Virtual Router ID [預設: 51]: " VRID
VRID="${VRID:-51}"

echo -e "\n${YELLOW}>>> [步驟 2/6] 安全密鑰與叢集密碼 (請輸入與 Node 1 相同之密碼)${NC}"

read -rp "請輸入 VRRP 心跳驗證密碼 [預設: SFTP_VRRP_PASS]: " VRRP_PASS
VRRP_PASS="${VRRP_PASS:-SFTP_VRRP_PASS}"

read -rp "請輸入 Node 1 上的 PostgreSQL sftpgo 密碼: " PG_PASS
read -rp "請輸入 Node 1 上的 PostgreSQL replicator 串流複寫密碼: " PG_REP_PASS

read -rp "請輸入 MinIO 根管理者帳號 [預設: minioadmin]: " MINIO_USER
MINIO_USER="${MINIO_USER:-minioadmin}"

read -rp "請輸入 MinIO 根管理者密碼 (需與 Node 1 相同): " MINIO_PASS

read -rp "請輸入 SFTPGo 管理者帳號 [預設: admin]: " SFTPGO_USER
SFTPGO_USER="${SFTPGO_USER:-admin}"

read -rp "請輸入 SFTPGo 管理者密碼 (需與 Node 1 相同): " SFTPGO_PASS

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

# 核心參數調優
sysctl -w net.ipv4.ip_nonlocal_bind=1 > /dev/null
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-sftp-ha.conf

# 4. 防火牆放行
echo -e "\n${YELLOW}>>> [步驟 4/6] 配置 Firewalld 防火牆規則...${NC}"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=2222/tcp --permanent  # SFTP VIP
  firewall-cmd --add-port=8081/tcp --permanent  # WebAdmin VIP
  firewall-cmd --add-port=8404/tcp --permanent  # HAProxy Stats
  firewall-cmd --add-port=5432/tcp --permanent  # PostgreSQL Standby
  firewall-cmd --add-port=9000-9001/tcp --permanent # MinIO API / Console
  firewall-cmd --add-port=2022/tcp --permanent  # SFTP Backend
  firewall-cmd --add-port=8080/tcp --permanent  # Web Backend
  firewall-cmd --add-protocol=vrrp --permanent  # VRRP
  firewall-cmd --reload
  echo -e "${GREEN}防火牆放行完成。${NC}"
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

# 確保 standby entrypoint 具備執行權限
chmod +x config/postgres/standby-entrypoint.sh

# 6. 拉起容器叢集
echo -e "\n${YELLOW}>>> [步驟 6/6] 啟動 Node 2 容器群集...${NC}"
docker compose pull
docker compose up -d

echo -e "等待 PostgreSQL Standby 完成 Node 1 基礎備份同步 (約 20 秒)..."
sleep 20

# 初始化本地 MinIO 並綁定雙向複寫
echo -e "配置 MinIO 雙向 S3 儲存桶鏡像複寫..."
chmod +x config/minio/setup-minio.sh
docker run --rm --network host -v "$SCRIPT_DIR/config/minio/setup-minio.sh:/setup.sh" \
  -e REMOTE_MINIO_HOST="$NODE1_IP" \
  -e MINIO_ROOT_USER="$MINIO_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_PASS" \
  cgr.dev/chainguard/minio:latest /bin/sh /setup.sh || true

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}       🎉 Node 2 (Backup) 已成功建置並加入 HA 叢集！            ${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "角色狀態:   Keepalived BACKUP (監控 Node 1 狀態，隨時準備接手 VIP)"
echo -e "資料庫狀態: PostgreSQL Standby (即時追蹤 Node 1 WAL 交易日誌)"
echo -e "物件儲存:   MinIO S3 (已與 Node 1 建立雙向即時複寫)"
echo -e "管理後台:   http://$NODE2_IP:8081"
echo -e "儀表板:     http://$NODE2_IP:8404"
