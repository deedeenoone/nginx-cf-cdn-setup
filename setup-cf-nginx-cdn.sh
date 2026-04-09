#!/bin/bash
#========================================
# Cloudflare + Nginx HTTPS 安全 CDN 一键配置脚本
# 支持多域名复用（每个域名独立证书和配置）
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

#---------- 检查参数 ----------
[ -z "$DOMAIN" ] && read -p "请输入你的域名 (如 api.example.com): " DOMAIN
[ -z "$SERVICE_PORT" ] && read -p "请输入内部服务端口 (如 13579): " SERVICE_PORT
[ -z "$CF_ZONE_ID" ] && read -p "请输入 Cloudflare Zone ID: " CF_ZONE_ID
[ -z "$CF_API_TOKEN" ] && read -p "请输入 Cloudflare API Token: " CF_API_TOKEN

info "开始配置..."

#========================================
# 0. 安全检查：避免重复配置同一域名
#========================================
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

if [ -f "$NGINX_CONF" ]; then
    info "检测到 ${DOMAIN} 已存在配置，跳过 Nginx/SSL 创建步骤..."
    info "如需重新配置，请先运行：sudo rm -f ${NGINX_CONF} ${NGINX_ENABLED}"
    SKIP_NGINX=1
else
    SKIP_NGINX=0
fi

#========================================
# 1. 安装依赖
#========================================
info "安装 nginx curl ufw openssl..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx curl ufw openssl

info "依赖安装完成"

#========================================
# 2. 生成该域名专属的 Origin SSL 证书
#========================================
if [ "$SKIP_NGINX" -eq 0 ]; then
    info "生成 Cloudflare Origin SSL 证书..."

    mkdir -p /etc/ssl/certs /etc/ssl/private

    # 按域名隔离证书，避免覆盖
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "/etc/ssl/private/${DOMAIN}.key" \
        -out "/etc/ssl/certs/${DOMAIN}.pem" \
        -subj "/CN=$DOMAIN/O=Cloudflare-Origin" 2>/dev/null

    chmod 600 /etc/ssl/private/${DOMAIN}.key
    chmod 644 /etc/ssl/certs/${DOMAIN}.pem

    info "证书生成完成: /etc/ssl/certs/${DOMAIN}.pem"
fi

#========================================
# 3. 通过 Cloudflare API 添加 DNS 记录
#========================================
info "添加 Cloudflare DNS 记录..."

PUBLIC_IP=$(curl -s ifconfig.me)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s icanhazip.com)

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
# 4. 配置 Nginx（该域名专属）
#========================================
if [ "$SKIP_NGINX" -eq 0 ]; then
    info "配置 Nginx..."

    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    # ========== SSL 配置（该域名专属证书） ==========
    ssl_certificate /etc/ssl/certs/${DOMAIN}.pem;
    ssl_certificate_key /etc/ssl/private/${DOMAIN}.key;
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

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        proxy_cache off;
    }
}
EOF

    # 启用站点（如果未启用）
    [ ! -L "$NGINX_ENABLED" ] && ln -s "$NGINX_CONF" "$NGINX_ENABLED" || info "站点已启用"

    # 测试并重载
    nginx -t && systemctl reload nginx

    info "Nginx 配置完成"
fi

#========================================
# 5. 防火墙：每个域名只允许 Cloudflare IP
#========================================
info "配置防火墙..."

# Cloudflare IPv4/IPv6 列表
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

ufw --force enable 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true

for ip in "${CF_IPS[@]}"; do
    # 检查规则是否已存在，避免重复添加
    ufw status | grep -q "$ip.*443" && continue
    ufw allow from $ip to any port 443 proto tcp comment "Cloudflare" 2>/dev/null || true
done

ufw reload 2>/dev/null || true

info "防火墙配置完成"

#========================================
# 6. 阻止直接 IP 访问（仅创建一次）
#========================================
BLOCK_CONF="/etc/nginx/sites-available/block-default"

if [ ! -f "$BLOCK_CONF" ]; then
    info "创建 block-default 配置（阻止直接 IP 访问）..."

    cat > "$BLOCK_CONF" << 'EOF'
server {
    listen 443 default_server;
    server_name _;
    ssl_certificate /etc/ssl/certs/cloudflare-origin.pem;
    ssl_certificate_key /etc/ssl/private/cloudflare-origin.key;
    return 444;
}
EOF

    ln -sf "$BLOCK_CONF" /etc/nginx/sites-enabled/block-default
    systemctl reload nginx
    info "block-default 已创建"
else
    info "block-default 已存在，跳过"
fi

#========================================
# 7. 输出结果
#========================================
echo ""
echo "========================================"
echo -e "${GREEN}配置完成！${NC}"
echo "========================================"
echo "域名:        https://${DOMAIN}"
echo "证书:        /etc/ssl/certs/${DOMAIN}.pem"
echo "私钥:        /etc/ssl/private/${DOMAIN}.key"
echo "Nginx配置:   ${NGINX_CONF}"
echo "内部服务:    localhost:${SERVICE_PORT}"
echo "公网IP:      ${PUBLIC_IP}"
echo ""
echo "已存在的域名配置:"
ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v block-default
echo ""
echo "请确保 Cloudflare SSL/TLS 模式设置为:"
echo -e "  ${GREEN}Full (strict)${NC}"
echo ""
echo "Cloudflare Dashboard 检查:"
echo "  DNS 记录应为 ${YELLOW}橙色云 (Proxied)${NC}"
echo "========================================"
