#!/bin/bash
#========================================
# Cloudflare + Nginx HTTPS 安全 CDN 一键配置脚本
# 支持多域名复用 + 自动续期 SSL
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
#
#   卸载:
#     curl -fsSL https://raw.githubusercontent.com/deedeenoone/cf-nginx-cdn-setup/main/setup-cf-nginx-cdn.sh | sudo bash -s -- --uninstall --domain api.example.com
#========================================

set -e

#---------- 默认值 ----------
DOMAIN=""
SERVICE_PORT=""
CF_ZONE_ID=""
CF_API_TOKEN=""
UNINSTALL=0
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
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        *)
            error "未知参数: $1"
            ;;
    esac
done

#---------- 辅助函数：卸载 ----------
uninstall_domain() {
    info "开始卸载 ${DOMAIN} 的配置..."

    # 禁用 Nginx site
    NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
    NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

    [ -f "$NGINX_CONF" ] && rm -f "$NGINX_CONF" && info "已删除 Nginx 配置: $NGINX_CONF"
    [ -L "$NGINX_ENABLED" ] && rm -f "$NGINX_ENABLED" && info "已禁用站点: $NGINX_ENABLED"

    # ========== acme.sh 清理 ==========
    if [ -d "$HOME/.acme.sh/${DOMAIN}" ] || [ -f "$HOME/.acme.sh/${DOMAIN}.conf" ]; then
        # 停止该域名的自动续期 cron 任务
        crontab -l 2>/dev/null | grep -v "acme.sh.*--renew.*${DOMAIN}" | crontab - 2>/dev/null || true
        # 移除 acme.sh 证书记录（会清理 cron + 配置）
        "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN" 2>/dev/null || true
        # 彻底删除该域名目录
        [ -d "$HOME/.acme.sh/${DOMAIN}" ] && rm -rf "$HOME/.acme.sh/${DOMAIN}"
        info "已清理 acme.sh 续期任务和证书"
    fi

    # 清理 acme.sh 存储的 Cloudflare API Token（如果该域名是唯一使用它的）
    if [ -f "$HOME/.acme.sh/account.conf" ]; then
        # 检查是否还有其他域名使用 CF DNS
        remaining_cf=$(ls "$HOME/.acme.sh/" 2>/dev/null | grep -c '.conf$' || true)
        if [ "$remaining_cf" -le 1 ]; then
            sed -i '/CF_Token/d' "$HOME/.acme.sh/account.conf" 2>/dev/null || true
            info "已清理 acme.sh Cloudflare API Token"
        fi
    fi

    # ========== 停止 Nginx 并清理证书 ==========
    [ -f "/etc/ssl/certs/${DOMAIN}.pem" ] && rm -f "/etc/ssl/certs/${DOMAIN}.pem" && info "已删除证书"
    [ -f "/etc/ssl/private/${DOMAIN}.key" ] && rm -f "/etc/ssl/private/${DOMAIN}.key" && info "已删除私钥"

    systemctl reload nginx
    info "${DOMAIN} 卸载完成"
    exit 0
}

#---------- UNINSTALL 模式 ----------
if [ "$UNINSTALL" -eq 1 ]; then
    [ -z "$DOMAIN" ] && error "卸载需要 --domain 参数"
    uninstall_domain
fi

#---------- 检查 root ----------
[ "$EUID" -ne 0 ] && error "请使用 root 或 sudo 运行"

#---------- 检查参数 ----------
[ -z "$DOMAIN" ] && read -p "请输入你的域名 (如 api.example.com): " DOMAIN
[ -z "$SERVICE_PORT" ] && read -p "请输入内部服务端口 (如 13579): " SERVICE_PORT
[ -z "$CF_ZONE_ID" ] && read -p "请输入 Cloudflare Zone ID: " CF_ZONE_ID
[ -z "$CF_API_TOKEN" ] && read -p "请输入 Cloudflare API Token: " CF_API_TOKEN

info "开始配置..."

#========================================
# 0. 安全检查：避免重复配置
#========================================
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

if [ -f "$NGINX_CONF" ]; then
    info "检测到 ${DOMAIN} 已存在配置，跳过创建步骤..."
    info "如需重新配置，请先卸载："
    echo "  curl ... | sudo bash -s -- --uninstall --domain ${DOMAIN}"
    SKIP_CREATE=1
else
    SKIP_CREATE=0
fi

#========================================
# 1. 安装依赖
#========================================
info "安装 nginx curl ufw openssl acme.sh..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx curl ufw openssl socat

# 安装 acme.sh（Let's Encrypt / 通用证书工具）
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh -s email=root@localhost.com
fi

info "依赖安装完成"

#========================================
# 2. 安装 acme.sh 并申请 Origin CA 证书（自动续期）
#========================================
if [ "$SKIP_CREATE" -eq 0 ]; then
    info "通过 acme.sh + Cloudflare API 申请 SSL 证书（自动续期）..."

    # 配置 Cloudflare API Token（写入 acme.sh 配置）
    export CF_Token="$CF_API_TOKEN"

    # 申请证书（Cloudflare DNS 验证，ZeroSSL CA）
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt 2>/dev/null || true

    "$HOME/.acme.sh/acme.sh" --issue \
        --dns dns_cf \
        -d "$DOMAIN" \
        --keylength 2048 \
        --auto-upgrade 1 \
        --home "$HOME/.acme.sh" \
        --config-home "$HOME/.acme.sh" \
        2>&1 | tail -5

    # 安装证书到 Nginx 目录
    mkdir -p /etc/ssl/certs /etc/ssl/private

    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
        --key-file "/etc/ssl/private/${DOMAIN}.key" \
        --cert-file "/etc/ssl/certs/${DOMAIN}.pem" \
        --reloadcmd "systemctl reload nginx" \
        --home "$HOME/.acme.sh" \
        --config-home "$HOME/.acme.sh" \
        2>&1 | tail -3

    chmod 600 /etc/ssl/private/${DOMAIN}.key
    chmod 644 /etc/ssl/certs/${DOMAIN}.pem

    info "证书安装完成（自动续期已配置）"
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
# 4. 配置 Nginx
#========================================
if [ "$SKIP_CREATE" -eq 0 ]; then
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

    # ========== SSL 配置（自动续期证书） ==========
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

    [ ! -L "$NGINX_ENABLED" ] && ln -s "$NGINX_CONF" "$NGINX_ENABLED" || info "站点已启用"
    [ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default

    nginx -t && systemctl reload nginx

    info "Nginx 配置完成"
fi

#========================================
# 5. 配置防火墙
#========================================
info "配置防火墙..."

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
    cat > "$BLOCK_CONF" << 'EOF'
server {
    listen 443 default_server;
    server_name _;
    ssl_certificate /etc/ssl/certs/${DOMAIN}.pem;
    ssl_certificate_key /etc/ssl/private/${DOMAIN}.key;
    return 444;
}
EOF
    ln -sf "$BLOCK_CONF" /etc/nginx/sites-enabled/block-default
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
echo "已配置的域名:"
ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v block-default
echo ""
echo "证书续期:    ${GREEN}自动（acme.sh 每 60 天续期）${NC}"
echo ""
echo "请确保 Cloudflare SSL/TLS 模式设置为:"
echo -e "  ${GREEN}Full (strict)${NC}"
echo ""
echo "Cloudflare Dashboard 检查:"
echo "  DNS 记录应为 ${YELLOW}橙色云 (Proxied)${NC}"
echo "========================================"
