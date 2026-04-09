# Cloudflare + Nginx HTTPS CDN 一键配置脚本

通过 Cloudflare API Token + Nginx 反向代理，将内部 HTTP 服务安全暴露为 HTTPS CDN 访问。

## 功能

- 自动申请 Cloudflare Origin SSL 证书
- 自动添加 DNS 记录（Proxied 模式）
- Nginx 反向代理 + 安全头配置
- 防火墙仅允许 Cloudflare IP 访问（防扫描）
- 阻止直接 IP 访问 443

## 前置要求

- 有一个 Cloudflare 托管的域名
- Cloudflare API Token（Zone:DNS:Edit 权限）
- 服务器公网 IP 可访问
- Ubuntu/Debian 系统

## 使用方法

```bash
# 1. 下载脚本
git clone https://github.com/deedeenoone/cf-nginx-cdn-setup.git
cd cf-nginx-cdn-setup

# 2. 编辑配置（脚本内）
nano setup-cf-nginx-cdn.sh
# 修改以下变量：
#   DOMAIN="api.example.com"
#   SERVICE_PORT="13579"
#   CF_ZONE_ID="your-zone-id"
#   CF_API_TOKEN="your-api-token"

# 3. 运行
chmod +x setup-cf-nginx-cdn.sh
sudo ./setup-cf-nginx-cdn.sh
```

## 交互模式

如果脚本内未填写配置，运行时会提示输入：

```bash
sudo ./setup-cf-nginx-cdn.sh
# 依次输入：
#   域名 (如 api.example.com)
#   内部服务端口 (如 13579)
#   Cloudflare Zone ID
#   Cloudflare API Token
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
