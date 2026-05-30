#!/bin/bash
# ============================================================
# 一键部署脚本 - 助记词批量扫描工具
# 适用于 Ubuntu 22.04 (阿里云 2C2G)
# ============================================================
set -e

echo "========================================"
echo "  助记词批量扫描工具 - 部署脚本"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}[1/5] 更新系统包...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv git curl ufw

echo -e "${YELLOW}[2/5] 克隆项目...${NC}"
cd /opt
if [ -d mnemonic-scanner ]; then
    echo "项目已存在，更新中..."
    cd mnemonic-scanner
    git pull
else
    git clone https://github.com/your-username/mnemonic-scanner.git
    cd mnemonic-scanner
fi

echo -e "${YELLOW}[3/5] 安装 Python 依赖...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo -e "${YELLOW}[4/5] 配置防火墙...${NC}"
ufw allow 8000/tcp
ufw --force enable

echo -e "${YELLOW}[5/5] 创建 systemd 服务...${NC}"
cat > /etc/systemd/system/mnemonic-scanner.service << 'SERVICEEOF'
[Unit]
Description=Mnemonic Scanner Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mnemonic-scanner
ExecStart=/opt/mnemonic-scanner/venv/bin/uvicorn wsgi:app --host 0.0.0.0 --port 8000 --workers 1 --log-level info
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable mnemonic-scanner
systemctl restart mnemonic-scanner

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}  访问地址: http://$(curl -s ifconfig.me):8000${NC}"
echo -e "${GREEN}  管理命令:${NC}"
echo -e "${GREEN}    systemctl status mnemonic-scanner${NC}"
echo -e "${GREEN}    systemctl restart mnemonic-scanner${NC}"
echo -e "${GREEN}    journalctl -u mnemonic-scanner -f${NC}"
echo -e "${GREEN}========================================${NC}"
