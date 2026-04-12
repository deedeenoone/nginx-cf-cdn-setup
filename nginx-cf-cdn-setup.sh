#!/bin/bash
# Nginx + Cloudflare HTTPS CDN Setup
# Features: Cloudflare-only access, auto SSL, firewall, block direct IP

set -e

DOMAIN=""
PORT=""
ZONE_ID=""
CF_TOKEN=""
CA="letsencrypt"

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --zone-id) ZONE_ID="$2"; shift 2 ;;
        --token) CF_TOKEN="$2"; shift 2 ;;
        --server) CA="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$DOMAIN" ]] && read -p "Domain: " DOMAIN
[[ -z "$PORT" ]] && read -p "Port: " PORT
[[ -z "$ZONE_ID" ]] && read -p "Zone ID: " ZONE_ID
[[ -z "$CF_TOKEN" ]] && read -p "CF Token: " CF_TOKEN

echo "[INFO] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq nginx curl ufw openssl socat > /dev/null 2>&1

echo "[INFO] Installing acme.sh..."
curl https://get.acme.sh | sh -s email=root@localhost.com > /dev/null 2>&1

echo "[INFO] Getting certificate..."
export CF_Token="$CF_TOKEN"
~/.acme.sh/acme.sh --set-default-ca --server "$CA" || { echo "[ERROR] Failed to set CA"; exit 1; }
echo "[INFO] Issuing certificate..."
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --server "$CA" || { echo "[ERROR] Certificate issue failed"; exit 1; }
echo "[INFO] Installing certificate..."
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/ssl/private/"$DOMAIN".key \
    --cert-file /etc/ssl/certs/"$DOMAIN".pem \
    --reloadcmd "systemctl reload nginx" || { echo "[ERROR] Certificate install failed"; exit 1; }

chmod 600 /etc/ssl/private/"$DOMAIN".key 2>/dev/null || true
chmod 644 /etc/ssl/certs/"$DOMAIN".pem 2>/dev/null || true

IP=$(curl -s ifconfig.me)
echo "[INFO] Adding DNS record ($IP)..."
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"proxied\":true}" > /dev/null

echo "[INFO] Configuring firewall (Cloudflare IPs only)..."
# Cloudflare IPv4 ranges
ufw --force enable > /dev/null 2>&1 || true
ufw default deny incoming > /dev/null 2>&1 || true
ufw allow 22/tcp > /dev/null 2>&1 || true
ufw allow 80/tcp > /dev/null 2>&1 || true

for cidr in "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22" \
            "141.101.64.0/18" "108.162.192.0/18" "172.64.0.0/13" "131.0.72.0/22" \
            "104.16.0.0/13" "104.24.0.0/14" "162.158.0.0/15" "198.41.128.0/17"; do
    ufw allow from $cidr to any port 443 proto tcp > /dev/null 2>&1 || true
done
ufw reload > /dev/null 2>&1 || true

echo "[INFO] Writing nginx config..."
cat > /etc/nginx/sites-available/"$DOMAIN" << NGX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/certs/$DOMAIN.pem;
    ssl_certificate_key /etc/ssl/private/$DOMAIN.key;
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

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
NGX

# Block direct IP access
cat > /etc/nginx/sites-available/block-default << NGX
server {
    listen 443 default_server;
    server_name _;
    ssl_certificate /etc/ssl/certs/$DOMAIN.pem;
    ssl_certificate_key /etc/ssl/private/$DOMAIN.key;
    return 444;
}
NGX

ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/"$DOMAIN"
ln -sf /etc/nginx/sites-available/block-default /etc/nginx/sites-enabled/block-default
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx

echo "[OK] Done! https://$DOMAIN"
echo "    - SSL: auto-renewing via acme.sh"
echo "    - Firewall: only Cloudflare IPs can access :443"
echo "    - Direct IP access: blocked"
