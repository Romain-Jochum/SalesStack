# Production Deployment Guide

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- At least 8 GB RAM (16 GB recommended)
- 40 GB+ disk space
- A separate Nginx VM for reverse proxy + TLS (or the same host if preferred)

## 1. Get the code on the server

**Option A: Git clone (recommended)**

```bash
ssh user@server
git clone https://github.com/YOUR_USER/SalesStack.git /opt/salesstack
cd /opt/salesstack
chmod +x scripts/*.sh
```

**Option B: rsync from local machine**

```bash
rsync -avz --exclude='volumes/' --exclude='.env' \
  /path/to/SalesStack/ \
  user@server:/opt/salesstack/
```

## 2. Generate secrets on the server

```bash
cd /opt/salesstack
./scripts/generate-secrets.sh
```

## 3. Edit .env for production

Update these values in `.env`:

```bash
# Change localhost URLs to your real domains
TWENTY_SERVER_URL=https://crm.example.com
MAUTIC_SITE_URL=https://mautic.example.com
WAHA_BASE_URL=https://wa.example.com
N8N_WEBHOOK_URL=https://n8n.example.com/

# Disable prefilled sign-in for production
TWENTY_SIGN_IN_PREFILLED=false
```

## 4. Start the stack

```bash
./scripts/start.sh
./scripts/post-deploy.sh   # Wait for healthy, print next steps
```

## 5. Nginx reverse proxy configuration

Nginx runs on a **separate VM** (or the same host). Each subdomain proxies to the sales stack server's internal IP. Replace `10.0.0.5` with the actual internal IP of the Docker host.

### crm.example.com (Twenty CRM)

```nginx
server {
    listen 443 ssl http2;
    server_name crm.example.com;

    ssl_certificate /etc/letsencrypt/live/crm.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/crm.example.com/privkey.pem;

    client_max_body_size 50M;

    location / {
        proxy_pass http://10.0.0.5:2350;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### mautic.example.com (Mautic)

```nginx
server {
    listen 443 ssl http2;
    server_name mautic.example.com;

    ssl_certificate /etc/letsencrypt/live/mautic.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mautic.example.com/privkey.pem;

    client_max_body_size 512M;
    proxy_read_timeout 600s;

    location / {
        proxy_pass http://10.0.0.5:2351;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### wa.example.com (WAHA)

```nginx
server {
    listen 443 ssl http2;
    server_name wa.example.com;

    ssl_certificate /etc/letsencrypt/live/wa.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/wa.example.com/privkey.pem;

    client_max_body_size 50M;

    location / {
        proxy_pass http://10.0.0.5:2352;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### n8n.example.com (n8n)

```nginx
server {
    listen 443 ssl http2;
    server_name n8n.example.com;

    ssl_certificate /etc/letsencrypt/live/n8n.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/n8n.example.com/privkey.pem;

    client_max_body_size 50M;
    proxy_read_timeout 300s;

    location / {
        proxy_pass http://10.0.0.5:2353;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### HTTP → HTTPS redirect (all domains)

```nginx
server {
    listen 80;
    server_name crm.example.com mautic.example.com wa.example.com n8n.example.com;
    return 301 https://$host$request_uri;
}
```

## 6. Cloudflare DNS

Create A records pointing to the **Nginx VM's public IP**:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | crm | 203.0.113.10 | Proxied or DNS only |
| A | mautic | 203.0.113.10 | Proxied or DNS only |
| A | wa | 203.0.113.10 | Proxied or DNS only |
| A | n8n | 203.0.113.10 | Proxied or DNS only |

If using Cloudflare proxy (orange cloud), set SSL mode to "Full (strict)" and ensure your origin certificates are valid.

## 7. Post-deploy checklist

1. Run `./scripts/post-deploy.sh` — verify all services healthy
2. Create admin accounts in Twenty, Mautic, and n8n (first visit)
3. Generate API keys:
   - Twenty: Settings -> APIs & Webhooks -> + Create key
   - n8n: Settings -> API -> Create API key
   - Mautic: Configuration -> API Settings -> Enable API + Basic Auth
4. Scan WAHA QR code for WhatsApp authentication
5. Configure webhooks:
   - Twenty webhook → `https://n8n.example.com/webhook/twenty-sync`
   - Mautic webhook → auto-registered by n8n Mautic Trigger node
   - WAHA session webhook → `https://n8n.example.com/webhook/waha-incoming`
6. Update MCP server configs with real API keys

## Firewall rules

On the Docker host, only allow inbound from the Nginx VM:

```bash
# Allow Nginx VM to reach service ports
ufw allow from 10.0.0.1 to any port 2350:2357 proto tcp

# Block all other access to service ports
ufw deny 2350:2399/tcp
```
