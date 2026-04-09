# Cloudflare + Nginx HTTPS CDN 一键配置脚本

通过 Cloudflare API Token + Nginx 反向代理，将内部 HTTP 服务安全暴露为 HTTPS CDN 访问。

## 功能

- 自动生成 Cloudflare Origin SSL 证书
- 自动添加 DNS 记录（Proxied 模式）
- Nginx 反向代理 + 安全头配置
- 防火墙仅允许 Cloudflare IP 访问（防扫描）
- 阻止直接 IP 访问 443

## 前置要求

- 有一个 Cloudflare 托管的域名
- Cloudflare API Token（Zone:DNS:Edit 权限）
- 服务器公网 IP 可访问
- Ubuntu/Debian 系统

## 一键安装（curl）

```bash
curl -fsSL https://raw.githubusercontent.com/deedeenoone/cf-nginx-cdn-setup/main/setup-cf-nginx-cdn.sh | sudo bash -s -- \
  --domain api.example.com \
  --port 13579 \
  --zone-id 你的ZoneID \
  --token 你的APIToken
```

**示例：**
```bash
curl -fsSL https://raw.githubusercontent.com/deedeenoone/cf-nginx-cdn-setup/main/setup-cf-nginx-cdn.sh | sudo bash -s -- \
  --domain api.mydomain.com \
  --port 13579 \
  --zone-id abc123def456 \
  --token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

## 交互模式

如果不想传参，可以直接运行脚本，按提示输入：

```bash
git clone https://github.com/deedeenoone/cf-nginx-cdn-setup.git
cd cf-nginx-cdn-setup
chmod +x setup-cf-nginx-cdn.sh
sudo ./setup-cf-nginx-cdn.sh
# 依次输入：域名、服务端口、Zone ID、API Token
```

## 架构

```
用户 → Cloudflare CDN (HTTPS) → Nginx (SSL Termination) → 内部服务:13579
```

## 安全特性

- 全链路 HTTPS 加密
- 仅 Cloudflare IP 可访问源站
- 阻止直接 IP 访问
- 完整安全响应头（X-Frame-Options, X-Content-Type-Options 等）
- Cloudflare DDoS 防护隐藏真实 IP

## Cloudflare SSL/TLS 设置

在 Cloudflare Dashboard 中设置：

1. **SSL/TLS** → **Overview** → **Full (strict)**
2. **SSL/TLS** → **Edge Certificates** → 开启 **Always Use HTTPS**
3. **WAF** → 按需开启规则

## License

MIT
