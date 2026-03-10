# SSL/TLS Certificates

## Overview

The mempool stack supports three TLS modes for securing web and RPC traffic:

| Mode | Use Case | Certificate Management |
|------|----------|----------------------|
| **none** | Local/dev, or behind Cloudflare Tunnel | No encryption (HTTP only) |
| **self-signed** | Internal networks, testing | Generated locally, 365-day validity |
| **letsencrypt** | Production with a public domain | Automatic via Let's Encrypt, auto-renewal |

The TLS mode is set during the wizard or by editing `TLS_MODE` in `node.conf`.

---

## Self-Signed Certificates

Self-signed certificates encrypt traffic but are not trusted by browsers (users will see a warning). Suitable for internal access or testing.

### Generate

```bash
# Uses domain from node.conf (DOMAIN_WEB), or defaults to localhost
./scripts/ssl/generate-self-signed.sh

# Specify a domain explicitly
./scripts/ssl/generate-self-signed.sh --domain mempool.local

# Dry run (show what would happen without writing files)
./scripts/ssl/generate-self-signed.sh --dry-run
```

### Certificate Details

| Property | Value |
|----------|-------|
| Key size | 2048-bit RSA |
| Signature | SHA-256 |
| Validity | 365 days |
| SAN | Specified domain + `localhost` + `127.0.0.1` |

### Output Files

```
config/openresty/ssl/
├── server.crt    (certificate, PEM format)
└── server.key    (private key, PEM format, mode 600)
```

These are bind-mounted into the OpenResty container at `/etc/openresty/ssl/` (read-only).

### Renewal

Self-signed certificates expire after 365 days. Re-run the script to generate a new one:

```bash
./scripts/ssl/generate-self-signed.sh
docker compose restart openresty
```

---

## Let's Encrypt Certificates

Let's Encrypt provides free, trusted SSL certificates. Requires a publicly-resolvable domain name and port 80 accessible from the internet.

### Prerequisites

- A **real domain name** pointing to your server's public IP (A record)
- **Port 80** open and accessible from the internet (for HTTP-01 challenge)
- **Root access** (needed to bind port 80 and write to `/etc/letsencrypt`)
- Either **certbot** or **acme.sh** installed

Install certbot:

```bash
sudo apt-get install certbot
```

Or install acme.sh:

```bash
curl https://get.acme.sh | sh
```

The script prefers certbot and falls back to acme.sh automatically.

### Obtain a Certificate

```bash
# Basic usage (reads domain/email from node.conf if set)
sudo ./scripts/ssl/setup-letsencrypt.sh --domain mempool.example.com --email you@example.com

# Test with staging server first (no rate limits, untrusted cert)
sudo ./scripts/ssl/setup-letsencrypt.sh --domain mempool.example.com --email you@example.com --staging

# Dry run (no certificate obtained)
./scripts/ssl/setup-letsencrypt.sh --domain mempool.example.com --email you@example.com --dry-run
```

The script will:
1. Temporarily stop OpenResty (to free port 80 for the challenge)
2. Run the HTTP-01 challenge via certbot or acme.sh
3. Store certificates at the standard Let's Encrypt path
4. Restart OpenResty
5. Set up automatic renewal

### Certificate Paths

```
/etc/letsencrypt/live/mempool.example.com/
├── fullchain.pem    (certificate chain)
└── privkey.pem      (private key)
```

These are bind-mounted from the host into OpenResty at `/etc/letsencrypt/` (read-only).

### Automatic Renewal

**certbot:** The script enables the systemd timer (`certbot.timer`) and installs a deploy hook at `/etc/letsencrypt/renewal-hooks/deploy/reload-openresty.sh` that reloads OpenResty after renewal.

**acme.sh:** The script adds a daily cron entry (runs at 03:00) that checks for renewal and reloads OpenResty on success.

Both tools handle renewal automatically — certificates are renewed before they expire (typically at 60 days of the 90-day validity).

### Troubleshooting Let's Encrypt

**"Domain does not resolve to this server":**
- Verify the A record: `dig +short mempool.example.com`
- The returned IP must match your server's public IP

**"Port 80 not accessible":**
- Check firewall: `sudo ufw status`
- If behind a router, ensure port 80 is forwarded
- If using Cloudflare Tunnel, you don't need Let's Encrypt (Cloudflare manages TLS)

**"Rate limit exceeded":**
- Let's Encrypt limits ~5 duplicate certificates per week per domain
- Use `--staging` for testing (staging has much higher limits)
- Wait and retry after the rate limit window passes

**"certbot not found":**
- Install: `sudo apt-get install certbot`
- Or the script will fall back to acme.sh if installed

---

## Configuring TLS Mode

### During Wizard

The wizard prompts for TLS configuration:

```
──── SSL/TLS ────
TLS mode [none/self-signed/letsencrypt]: letsencrypt
Domain name: mempool.example.com
Email for Let's Encrypt: you@example.com
```

### In node.conf

```ini
TLS_MODE=letsencrypt
DOMAIN_WEB=mempool.example.com
LETSENCRYPT_EMAIL=you@example.com

# Or for self-signed:
TLS_MODE=self-signed
DOMAIN_WEB=mempool.local

# Or disabled:
TLS_MODE=none
```

After changing `TLS_MODE`, regenerate configs:

```bash
./scripts/setup/generate-config.sh
docker compose up -d
```

### What Changes by TLS Mode

| Config Area | `none` | `self-signed` | `letsencrypt` |
|-------------|--------|---------------|---------------|
| **nginx.conf** | `listen 80` only | `listen 443 ssl` + cert paths | `listen 443 ssl` + cert paths |
| **Docker volumes** | — | `./config/openresty/ssl:/etc/openresty/ssl:ro` | `/etc/letsencrypt:/etc/letsencrypt:ro` |
| **Firewall** | Port 80 only | Ports 80 + 443 | Ports 80 + 443 |

---

## TLS Mode Decision Guide

| Scenario | Recommended Mode |
|----------|-----------------|
| Local development / testing | `none` or `self-signed` |
| Internal network, no public domain | `self-signed` |
| Public server with a domain | `letsencrypt` |
| Behind Cloudflare Tunnel | `none` (Cloudflare handles TLS) |
| Behind another reverse proxy with TLS | `none` |

When using Cloudflare Tunnel, the tunnel encrypts traffic between Cloudflare and your server. Setting `TLS_MODE=none` avoids double encryption and certificate management complexity.
