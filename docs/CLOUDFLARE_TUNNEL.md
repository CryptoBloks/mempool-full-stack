# Cloudflare Tunnel

## Overview

Cloudflare Tunnel provides zero-trust remote access to your mempool stack without opening any inbound ports. Traffic flows outbound from your server through an encrypted tunnel to Cloudflare's edge network, then to your users via Cloudflare's CDN.

When enabled, the `cloudflared` container connects to Cloudflare and routes incoming traffic to your local services. The firewall rules automatically adapt — web and RPC ports are **not** opened publicly since all traffic arrives through the tunnel.

```
User → Cloudflare CDN → Encrypted Tunnel → cloudflared container → OpenResty → Services
                                                (outbound only)
```

No inbound ports are required except Bitcoin P2P (8333/38333/18333) which always remains open for node connectivity.

---

## Prerequisites

1. A **Cloudflare account** (free tier works)
2. A **domain** added to Cloudflare (DNS managed by Cloudflare)
3. A **Cloudflare Tunnel** created in the Zero Trust dashboard

---

## Creating a Tunnel in Cloudflare

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Navigate to **Zero Trust** (left sidebar) → **Networks** → **Tunnels**
3. Click **Create a tunnel**
4. Choose **Cloudflared** as the connector type
5. Name your tunnel (e.g., `mempool-node`)
6. On the connector setup page, copy the **tunnel token** from the install command
   - It looks like: `eyJhIjoiNjM0NTY3ODkwYWJjZGVm...` (long base64 string)
   - You only need the token, not the full install command

### Configure Public Hostnames

In the Cloudflare dashboard, add public hostnames for your tunnel:

**Web interface:**

| Field | Value |
|-------|-------|
| Subdomain | `mempool` (or your choice) |
| Domain | `yourdomain.com` |
| Service Type | `HTTP` |
| URL | `openresty:80` |

**RPC endpoint** (optional, only if RPC gateway is enabled):

| Field | Value |
|-------|-------|
| Subdomain | `rpc` (or your choice) |
| Domain | `yourdomain.com` |
| Service Type | `HTTP` |
| URL | `openresty:80` |

The URL points to the OpenResty container inside the Docker network. Cloudflared connects to it via the `mempool_net` bridge.

---

## Setup

### During Initial Wizard

The wizard (`wizard.sh`) includes a Cloudflare Tunnel section:

```
──── Cloudflare Tunnel ────
Enable Cloudflare Tunnel for remote access? [y/N]: y
Paste your Cloudflare Tunnel token: eyJhIjoiNjM0NTY3...
Web hostname (e.g., mempool.yourdomain.com): mempool.example.com
RPC hostname (e.g., rpc.yourdomain.com, or empty to skip): rpc.example.com
```

The wizard stores these values in `node.conf`:

```ini
CLOUDFLARE_TUNNEL_ENABLED=true
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiNjM0NTY3...
CF_HOSTNAME_WEB=mempool.example.com
CF_HOSTNAME_RPC=rpc.example.com
```

### After Initial Setup

Use the dedicated setup script:

```bash
# Interactive mode (guided prompts)
./scripts/tunnel/setup-tunnel.sh

# Non-interactive mode (for automation)
./scripts/tunnel/setup-tunnel.sh --non-interactive --token eyJhIjoiNjM0NTY3...
```

The script:
1. Saves the tunnel token and hostnames to `node.conf`
2. Regenerates all configuration files (including tunnel-aware firewall rules)
3. Outputs next steps

### Starting the Tunnel

After setup, start (or restart) the stack:

```bash
docker compose up -d
```

The `cloudflared` container will:
- Read its config from `config/cloudflared/config.yml` (mounted read-only)
- Connect outbound to Cloudflare's edge network
- Route incoming traffic to the configured services

---

## How It Works

### Generated Configuration

`config/cloudflared/config.yml`:

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: mempool.example.com
    service: http://openresty:80
  - hostname: rpc.example.com
    service: http://openresty:80
  - service: http_status:404
```

The ingress rules route traffic by hostname to the OpenResty container, which then handles path-based routing to the correct backend (mempool web, API, or RPC gateway).

### Docker Compose

When tunnel is enabled, the generated `docker-compose.yml` includes:

```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  container_name: cloudflared
  command: tunnel --config /etc/cloudflared/config.yml run
  volumes:
    - ./config/cloudflared:/etc/cloudflared:ro
  depends_on:
    - openresty
  networks:
    - mempool_net
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  restart: unless-stopped
```

No ports are exposed — the container only makes outbound connections.

### Firewall Changes

When Cloudflare Tunnel is enabled, the generated firewall rules (`config/ufw-rules.sh`) automatically:

- **Skip** opening the web port (80/443) — traffic arrives via tunnel
- **Skip** opening the RPC port — traffic arrives via tunnel
- **Keep** Bitcoin P2P ports open (8333/38333/18333) — needed for node connectivity
- **Keep** SSH (22) open — for server management

This means your server has minimal attack surface: only SSH and Bitcoin P2P are accessible from the internet.

---

## Verifying the Tunnel

### Check Container Status

```bash
docker logs cloudflared
```

Healthy output:

```
INF Starting tunnel tunnelID=abc123
INF Connection established connIndex=0 ...
INF Connection established connIndex=1 ...
```

### Check in Cloudflare Dashboard

Go to **Zero Trust** → **Networks** → **Tunnels**. Your tunnel should show as **Healthy** with active connections.

### Test Access

```bash
# Web interface
curl -I https://mempool.yourdomain.com

# RPC endpoint (if configured)
curl -X POST https://rpc.yourdomain.com/v1/YOUR_API_KEY \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'
```

---

## Reconfiguring

To change the tunnel token or hostnames:

```bash
# Re-run the setup script (detects existing config and asks to overwrite)
./scripts/tunnel/setup-tunnel.sh
```

### Disabling the Tunnel

Set `CLOUDFLARE_TUNNEL_ENABLED=false` in `node.conf` and regenerate:

```bash
sed -i 's/CLOUDFLARE_TUNNEL_ENABLED=true/CLOUDFLARE_TUNNEL_ENABLED=false/' node.conf
./scripts/setup/generate-config.sh
docker compose up -d   # cloudflared container will not be created
```

The firewall rules will revert to opening web/RPC ports publicly.

---

## Tunnel vs. Direct Port Exposure

| Aspect | Direct Exposure | Cloudflare Tunnel |
|--------|----------------|-------------------|
| **Inbound ports** | Web (80/443) + RPC + P2P | P2P only |
| **DDoS protection** | None (unless external) | Cloudflare's network |
| **SSL certificates** | Self-signed or Let's Encrypt | Cloudflare-managed (automatic) |
| **DNS** | Manual A record | Automatic via tunnel hostname |
| **Latency** | Direct | Slight increase (Cloudflare edge hop) |
| **Setup complexity** | Lower | Requires Cloudflare account + tunnel |
| **Server IP exposure** | Public | Hidden behind Cloudflare |

---

## Troubleshooting

### Tunnel not connecting

- Check the token: `grep CLOUDFLARE_TUNNEL_TOKEN node.conf`
- Verify the token in Cloudflare dashboard matches
- Check container logs: `docker logs cloudflared`
- Ensure outbound HTTPS (443) is not blocked by your network

### Hostname not resolving

- Verify public hostnames are configured in the Cloudflare dashboard
- Check that your domain's DNS is managed by Cloudflare
- DNS propagation can take a few minutes after tunnel creation

### 502 Bad Gateway

- The cloudflared container can't reach OpenResty
- Check that OpenResty is running: `docker ps | grep openresty`
- Check Docker network: both containers must be on `mempool_net`

### Config not applied after changes

- Regenerate config: `./scripts/setup/generate-config.sh`
- Recreate containers: `docker compose up -d`
