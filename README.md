# Cloudflare + Nginx HTTPS CDN Setup

One-line setup for exposing internal HTTP services as HTTPS via Cloudflare CDN, using Cloudflare API Token + Nginx reverse proxy + acme.sh auto-renewal.

## Features

- Auto-issue Let's Encrypt / ZeroSSL SSL certificates (auto-renewal)
- Auto-add DNS records via Cloudflare API
- Nginx reverse proxy with security headers
- Firewall only allows Cloudflare IPs (anti-scan)
- Block direct IP access on 443
- **Automatic SSL renewal** (acme.sh, renews every 60 days)
- WebSocket support (optional `--websocket` flag)
- Idempotent: skip steps if already configured

## Requirements

- A domain hosted on Cloudflare
- Cloudflare API Token (Zone:DNS:Edit permissions)
- Server with public IP
- Ubuntu/Debian system

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/deedeenoone/nginx-cf-cdn-setup/main/nginx-cf-cdn-setup.sh | sudo bash -s -- \
  --domain api.example.com \
  --port 13579 \
  --zone-id yourZoneID \
  --token yourAPIToken
```

**With ZeroSSL (if Let's Encrypt is rate limited):**
```bash
curl -fsSL ... | sudo bash -s -- \
  --domain api.example.com \
  --port 13579 \
  --zone-id yourZoneID \
  --token yourAPIToken \
  --server zerossl
```

**With WebSocket support:**
```bash
curl -fsSL ... | sudo bash -s -- \
  --domain api.example.com \
  --port 13579 \
  --zone-id yourZoneID \
  --token yourAPIToken \
  --websocket
```

## Architecture

```
User → Cloudflare CDN (HTTPS) → Nginx (SSL Termination) → Internal Service:13579
                                        ↑
                                   acme.sh Auto-Renewal
```

## SSL Certificate Auto-Renewal

Uses [acme.sh](https://github.com/acmesh-official/acme.sh) + Cloudflare DNS API for Let's Encrypt certificates with auto-renewal:

- Certificate valid 60 days, acme.sh auto-renews before expiry
- Auto reloads Nginx after successful renewal, **zero downtime**
- Logs: `~/.acme.sh/${DOMAIN}/`

Check renewal status:
```bash
~/.acme.sh/acme.sh --list
```

## Uninstall

### Uninstall Single Domain

```bash
curl -fsSL https://raw.githubusercontent.com/deedeenoone/nginx-cf-cdn-setup/main/nginx-cf-cdn-setup.sh | sudo bash -s -- \
  --uninstall --domain api.example.com
```

This removes:
1. Nginx site config
2. SSL certificates and keys
3. acme.sh certificate records
4. Reloads Nginx

### Full Manual Uninstall

```bash
# Stop Nginx
systemctl stop nginx

# Remove all site configs
rm -f /etc/nginx/sites-available/*
rm -f /etc/nginx/sites-enabled/*

# Remove all certificates
rm -f /etc/ssl/certs/*.pem
rm -f /etc/ssl/private/*.key

# Remove acme.sh
rm -rf ~/.acme.sh

# Reload
systemctl reload nginx
```

### Reset Firewall

```bash
# Disable ufw
ufw disable

# Or reset rules
ufw reset
ufw default deny incoming
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
```

### Clean Cloudflare DNS Records

Manually log into [dash.cloudflare.com](https://dash.cloudflare.com) → your domain → DNS → delete the A record.

## Security Features

- End-to-end HTTPS encryption
- Only Cloudflare IPs can access origin
- Blocks direct IP access
- Full security response headers (X-Frame-Options, X-Content-Type-Options, etc.)
- Cloudflare DDoS protection hides real IP
- Auto-renewing certificates, never expire

## Cloudflare SSL/TLS Settings

Configure in Cloudflare Dashboard:

1. **SSL/TLS** → **Overview** → **Full (strict)**
2. **SSL/TLS** → **Edge Certificates** → Enable **Always Use HTTPS**
3. **WAF** → Enable rules as needed

## Idempotent Runs

The script is safe to run multiple times. It will skip steps that are already done:
- Dependencies already installed → skip
- Nginx already running → skip
- Certificate already issued → skip
- Certificate already installed → skip

## Files

- `nginx-cf-cdn-setup.sh` - Main setup script
- `nginx-cf-cdn-setup-202604.sh` - Backup from 2026-04

## License

MIT
