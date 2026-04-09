#!/bin/bash
#========================================
# Cloudflare + Nginx HTTPS 安全 CDN 一键配置脚本
# Author: auto-generated
# Usage:
#   非交互模式（curl 一键）:
#     curl -fsSL https://raw.githubusercontent.com/deedeenoone/cf-nginx-cdn-setup/main/setup-cf-nginx-cdn.sh | sudo bash -s -- \
#       --domain api.example.com \
#       --port 13579 \
#       --zone-id xxxxx \
#       --token xxxxx
#
#   交互模式:
#     sudo ./setup-cf-nginx-cdn.sh
#========================================

set -e

#---------- 默认值 ----------
DOMAIN=""
SERVICE_PORT=""
CF_ZONE_ID=""
CF_API_TOKEN=""
ORIGIN_CERT="/etc/ssl/certs/cloudflare-origin.pem"
ORIGIN_KEY="/etc/ssl/private/cloudflare-origin.key"
#------------------------------

#---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#---------- 命令行参数解析 ----------
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --port)
            SERVICE_PORT="$2"
            shift 2
            ;;
        --zone-id)
            CF_ZONE_ID="$2"
            shift 2
            ;;
        --token)
            CF_API_TOKEN="$2"
            shift 2
            ;;
        *)
            error "未知参数: $1"
            ;;
    esac
done

#---------- 检查 root ----------
[ "$EUID" -ne 0 ] && error "请使用 root 或 sudo 运行"

#---------- 检查参数（缺少则交互输入） ----------
[ -z "$DOMAIN" ] && read -p "请输入你的域名 (如 api.example.com): " DOMAIN
[ -z "$SERVICE_PORT" ] && read -p "请输入内部服务端口 (如 13579): " SERVICE_PORT
[ -z "$CF_ZONE_ID" ] && read -p "请输入 Cloudflare Zone ID: " CF_ZONE_ID
[ -z "$CF_API_TOKEN" ] && read -p "请输入 Cloudflare API Token: " CF_API_TOKEN

info "开始配置..."

#========================================
# 1. 安装依赖
#========================================
info "安装 nginx certbot curl ufw..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx curl ufw openssl

info "依赖安装完成"

#========================================
# 2. 生成 Origin SSL 证书
#========================================
info "生成 Cloudflare Origin SSL 证书..."

mkdir -p /etc/ssl/certs /etc/ssl/private

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$ORIGIN_KEY" \
  -out /etc/ssl/certs/cloudflare-origin.pem \
  -subj "/CN=$DOMAIN/O=Cloudflare-Origin" 2>/dev/null

info "证书生成完成"

#========================================
# 3. 通过 Cloudflare API 添加 DNS 记录
#========================================
info "添加 Cloudflare DNS 记录..."

# 获取服务器公网 IP
PUBLIC_IP=$(curl -s ifconfig.me)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s icanhazip.com)

# 添加 DNS A 记录（Proxied）
RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{
    \"type\": \"A\",
    \"name\": \"${DOMAIN}\",
    \"content\": \"${PUBLIC_IP}\",
    \"proxied\": true
  }")

if echo "$RESPONSE" | grep -q '"success":true'; then
    info "DNS 记录添加成功"
else
    warn "DNS 记录可能已存在或添加失败，请手动检查 Cloudflare Dashboard"
fi

#========================================
# 4. 配置 Nginx
#========================================
info "配置 Nginx..."

NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

cat > "$NGINX_CONF" << 'EOF'
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    # ========== SSL 配置 ==========
    ssl_certificate /etc/ssl/certs/cloudflare-origin.pem;
    ssl_certificate_key /etc/ssl/private/cloudflare-origin.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;

    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ========== 安全头 ==========
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # ========== 代理到内部服务 ==========
    location / {
        proxy_pass http://127.0.0.1:${SERVICE_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        proxy_cache off;
    }
}
EOF

# 替换占位符
sed -i "s/\${DOMAIN}/$DOMAIN/g; s/\${SERVICE_PORT}/$SERVICE_PORT/g" "$NGINX_CONF"

# 启用站点
ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
[ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default

# 测试并重载
nginx -t && systemctl reload nginx

info "Nginx 配置完成"

#========================================
# 5. 配置防火墙（仅允许 Cloudflare IP 访问）
#========================================
info "配置防火墙（仅允许 Cloudflare IP 访问 443）..."

# Cloudflare IPv4 列表
CF_IPS=(
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "172.64.0.0/13"
    "131.0.72.0/22"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "162.158.0.0/15"
    "198.41.128.0/17"
)

ufw --force enable
ufw default deny incoming
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'

for ip in "${CF_IPS[@]}"; do
    ufw allow from $ip to any port 443 proto tcp comment "Cloudflare" 2>/dev/null || true
done

ufw reload

info "防火墙配置完成"

#========================================
# 6. 阻止直接 IP 访问
#========================================
info "阻止直接 IP 访问 443..."

cat > /etc/nginx/sites-available/block-default \
<< 'EOF'
server {
    listen 443 default_server;
    server_name _;
    ssl_certificate /etc/ssl/certs/cloudflare-origin.pem;
    ssl_certificate_key /etc/ssl/private/cloudflare-origin.key;
    return 444;
}
EOF

ln -sf /etc/nginx/sites-available/block-default /etc/nginx/sites-enabled/block-default
systemctl reload nginx

info "完成！"

#========================================
# 输出结果
#========================================
echo ""
echo "========================================"
echo -e "${GREEN}配置完成！${NC}"
echo "========================================"
echo "域名:        https://${DOMAIN}"
echo "内部服务:    localhost:${SERVICE_PORT}"
echo "公网IP:      ${PUBLIC_IP}"
echo ""
echo "请确保 Cloudflare SSL/TLS 模式设置为:"
echo -e "  ${GREEN}Full (strict)${NC}"
echo ""
echo "Cloudflare Dashboard 检查:"
echo "  DNS 记录应为 ${YELLOW}橙色云 (Proxied)${NC}"
echo "========================================"
