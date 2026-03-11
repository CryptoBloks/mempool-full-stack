# Mempool.space Full Stack - On Docker

A configurator-driven, self-hosted Bitcoin infrastructure platform. Deploy a complete mempool.space block explorer with multi-network support, an optional RPC gateway, and full backup/restore — all driven by a single interactive wizard.

## What You Get

- **Mempool.space block explorer** — frontend + backend for mainnet, signet, and/or testnet
- **Bitcoin Core** — per-network full nodes
- **Electrs** — per-network Electrum server (indexer)
- **MariaDB** — shared database backend
- **OpenResty** — reverse proxy with Lua-based RPC gateway (optional)
- **Cloudflare Tunnel** — optional zero-trust remote access
- **BTRFS snapshot backup** — streaming to S3 with zstd compression

## Prerequisites

- Docker and Docker Compose (v2)
- Bash 4.0+
- 600GB+ disk space (mainnet), ~5GB (signet), ~30GB (testnet)
- 8GB+ RAM recommended
- Python 3 (for rpcauth HMAC generation)
- `jq` (for RPC key management scripts)

## Quick Start

```bash
git clone <repository-url>
cd mempool.space-full-stack-docker

# Run the interactive setup wizard
./scripts/setup/wizard.sh

# Start the stack
docker compose up -d
```

The wizard walks through 11 configuration sections: network selection, versions, storage, Bitcoin Core options, RPC endpoint, ports, SSL/TLS, Cloudflare Tunnel, firewall, and credentials. It generates `node.conf` and then calls `generate-config.sh` to produce all service configuration files.

### Non-Interactive Setup

```bash
# Generate default config (mainnet + signet) and all files
./scripts/setup/wizard.sh --non-interactive

docker compose up -d
```

## Architecture

### Configuration Flow

```
wizard.sh → node.conf → generate-config.sh → docker-compose.yml
                                            → config/{network}/bitcoin.conf
                                            → config/{network}/electrs.toml
                                            → config/{network}/mempool-config.json
                                            → config/openresty/nginx.conf
                                            → config/mariadb/init/01-init.sql
                                            → config/ufw-rules.sh
                                            → (optional) config/openresty/jsonrpc-access.lua
                                            → (optional) config/openresty/api-keys.json
                                            → (optional) config/cloudflared/config.yml
```

`node.conf` is the single source of truth. Re-running the wizard with an existing `node.conf` pre-fills previous values as defaults.

### Container Layout

Per-network services (one set per enabled network):
- `bitcoind-{network}` — Bitcoin Core full node
- `electrs-{network}` — Electrs indexer
- `mempool-api-{network}` — Mempool backend API

Shared services:
- `mariadb` — MariaDB database
- `mempool-web` — Mempool frontend
- `openresty` — Reverse proxy / RPC gateway
- `cloudflared` — Cloudflare Tunnel (optional)

All containers run on the `mempool_net` bridge network (172.20.0.0/24).

### Default Versions

| Component | Default Version |
|-----------|----------------|
| Bitcoin Core | 28.1 |
| Mempool | 3.1.0 |
| Electrs | latest |
| MariaDB | 10.11 |
| OpenResty | alpine |

## Node Management

```bash
# Start/stop/restart all or per-network
./scripts/node/start.sh [--network mainnet]
./scripts/node/stop.sh [--network mainnet]
./scripts/node/restart.sh [--network mainnet]

# View status (containers, sync progress, disk usage)
./scripts/node/status.sh

# Follow logs
./scripts/node/logs.sh [--service bitcoind-mainnet] [--follow] [--lines 100]
```

## RPC Gateway (Optional)

When `RPC_ENDPOINT_ENABLED=true`, OpenResty exposes a Bitcoin JSON-RPC endpoint with API key authentication, per-key rate limiting, method whitelisting, and per-network routing.

```bash
# Add an API key
./scripts/rpc/add-key.sh --name "my-app" --rate-limit 120

# Make a request (path-based auth)
curl -X POST http://your-server:3000/v2/YOUR_API_KEY \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}'

# Or use header-based auth
curl -X POST http://your-server:3000/v2/default \
  -H "Content-Type: application/json" \
  -H "X-API-Key: YOUR_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}'

# Per-network routing
curl -X POST http://your-server:3000/v2/YOUR_API_KEY/signet ...

# Manage keys
./scripts/rpc/list-keys.sh
./scripts/rpc/revoke-key.sh <key>

# Test the endpoint
./scripts/rpc/test-endpoint.sh --method getblockchaininfo
```

Method whitelist profiles control which RPC methods are accessible:
- **read-only** — 27 safe query methods (getblock, getblockchaininfo, estimatesmartfee, etc.)
- **standard** — read-only + sendrawtransaction, testmempoolaccept
- **full** — standard + wallet and advanced methods (admin use only)

Dangerous methods (`stop`, `dumpprivkey`, `dumpwallet`, `importprivkey`, etc.) are blocked in all profiles. Defense-in-depth: Bitcoin Core enforces a separate `rpcwhitelist` on the gateway's RPC user.

See **[docs/RPC_GATEWAY.md](docs/RPC_GATEWAY.md)** for the full guide: key management, method reference, rate limiting behavior, error codes, and CORS configuration.

## SSL/TLS

Three modes: `none`, `self-signed`, or `letsencrypt` (set during wizard or in `node.conf`).

```bash
# Self-signed certificate (2048-bit RSA, 365-day, SAN support)
./scripts/ssl/generate-self-signed.sh [--domain mempool.local]

# Let's Encrypt (requires public DNS + port 80 accessible)
sudo ./scripts/ssl/setup-letsencrypt.sh --domain mempool.example.com --email you@example.com

# Test with staging server first
sudo ./scripts/ssl/setup-letsencrypt.sh --domain mempool.example.com --email you@example.com --staging
```

Let's Encrypt certificates auto-renew via certbot timer or acme.sh cron. When using Cloudflare Tunnel, TLS is handled by Cloudflare — set `TLS_MODE=none`.

See **[docs/SSL_CERTIFICATES.md](docs/SSL_CERTIFICATES.md)** for details on each mode, prerequisites, and troubleshooting.

## Cloudflare Tunnel

Zero-trust remote access without opening inbound ports. Traffic flows outbound through an encrypted tunnel to Cloudflare's edge, then to your users.

```bash
# Interactive setup (guided prompts for token and hostnames)
./scripts/tunnel/setup-tunnel.sh

# Non-interactive (for automation)
./scripts/tunnel/setup-tunnel.sh --non-interactive --token eyJhIjoiNjM0...
```

When enabled:
- The `cloudflared` container connects outbound to Cloudflare (no inbound ports needed)
- Firewall rules automatically skip opening web/RPC ports (all traffic arrives via tunnel)
- Only SSH and Bitcoin P2P ports remain open
- Your server's IP is hidden behind Cloudflare

Prerequisites: Cloudflare account, domain managed by Cloudflare, a tunnel created in the Zero Trust dashboard.

See **[docs/CLOUDFLARE_TUNNEL.md](docs/CLOUDFLARE_TUNNEL.md)** for step-by-step setup, hostname configuration, and troubleshooting.

## Firewall

The generated `config/ufw-rules.sh` includes:
- Docker-aware UFW rules (DOCKER-USER iptables chain — prevents Docker from bypassing UFW)
- Tunnel-aware logic (web/RPC ports skipped when Cloudflare Tunnel is enabled)
- Bitcoin P2P ports always open (8333/38333/18333)
- SSH always allowed

## Backup & Restore

### BTRFS Snapshots (Recommended)

```bash
# Create snapshots
./scripts/snapshot/create.sh [--network mainnet]
./scripts/snapshot/list.sh
./scripts/snapshot/prune.sh --keep 5
```

### S3 Backup (Streaming)

```bash
# Full backup: stop → snapshot → restart → upload → prune
./scripts/backup/full-backup.sh --network mainnet

# List / prune remote backups
./scripts/backup/s3-list.sh
./scripts/backup/s3-prune.sh --keep 3

# Restore from S3 or local snapshot
./scripts/backup/restore.sh --network mainnet --source s3 --backup-id <id>
```

Backups stream via `tar | zstd -T0 -3 | rclone rcat` with no intermediate files. BTRFS-aware mode creates read-only snapshots for minimal downtime (~30-60s).

## Maintenance

```bash
# Health check (containers, sync, MariaDB, disk, Electrs)
./scripts/maintenance/health-check.sh

# Check for updates / apply updates
./scripts/maintenance/update.sh --check-only
./scripts/maintenance/update.sh
```

## Validation

```bash
# Validate node.conf + all generated files
./scripts/setup/validate-config.sh
```

## Project Structure

```
.
├── scripts/
│   ├── setup/
│   │   ├── wizard.sh              # Interactive configurator (11 sections)
│   │   ├── generate-config.sh     # Template renderer → all config files
│   │   └── validate-config.sh     # End-to-end config validator
│   ├── lib/
│   │   ├── common.sh              # Colors, logging, prompts, validators
│   │   ├── config-utils.sh        # node.conf read/write
│   │   └── network-defaults.sh    # Per-network defaults, versions, images
│   ├── node/
│   │   ├── start.sh, stop.sh, restart.sh
│   │   ├── status.sh, logs.sh
│   ├── rpc/
│   │   ├── add-key.sh, list-keys.sh, revoke-key.sh, test-endpoint.sh
│   ├── backup/
│   │   ├── full-backup.sh, restore.sh
│   │   ├── s3-push.sh, s3-pull.sh, s3-list.sh, s3-prune.sh
│   ├── snapshot/
│   │   ├── create.sh, list.sh, prune.sh
│   ├── ssl/
│   │   ├── generate-self-signed.sh, setup-letsencrypt.sh
│   ├── tunnel/
│   │   └── setup-tunnel.sh
│   └── maintenance/
│       ├── health-check.sh, update.sh
├── config/
│   └── templates/                 # 9 .tmpl files (tracked in git)
├── docker/
│   ├── Dockerfile.bitcoin         # Build-from-source (optional)
│   └── Dockerfile.fulcrum         # Build-from-source (optional)
├── docs/
│   ├── ARCHITECTURE.md            # System design and internals
│   ├── BACKUP.md                  # Backup, restore, and snapshot guide
│   ├── CLOUDFLARE_TUNNEL.md       # Cloudflare Tunnel setup guide
│   ├── RPC_GATEWAY.md             # RPC gateway and API key guide
│   └── SSL_CERTIFICATES.md        # SSL/TLS certificate guide
├── node.conf                      # Generated by wizard (gitignored)
├── docker-compose.yml             # Generated from template (gitignored)
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Documentation

| Document | Description |
|----------|-------------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design: config flow, multi-network layout, container inventory, security model |
| [docs/RPC_GATEWAY.md](docs/RPC_GATEWAY.md) | RPC gateway: API keys, method profiles, rate limiting, error codes, usage examples |
| [docs/CLOUDFLARE_TUNNEL.md](docs/CLOUDFLARE_TUNNEL.md) | Cloudflare Tunnel: prerequisites, setup, firewall changes, troubleshooting |
| [docs/SSL_CERTIFICATES.md](docs/SSL_CERTIFICATES.md) | SSL/TLS: self-signed, Let's Encrypt, auto-renewal, mode comparison |
| [docs/BACKUP.md](docs/BACKUP.md) | Backup & restore: BTRFS snapshots, S3 streaming, manifest format, restore procedures |
| [CHANGELOG.md](CHANGELOG.md) | Release notes and version history |

## Security

- All internal services (RPC, Electrs, MariaDB) are only exposed within the Docker network
- Containers enforce `no-new-privileges: true` and drop all capabilities
- Bitcoin P2P port (8333/38333/18333) is the only port exposed to the internet by default
- Web port (default 80) exposed for the frontend; skipped when using Cloudflare Tunnel
- RPC gateway uses API key authentication + rate limiting + method whitelisting
- Docker-aware UFW rules prevent Docker from bypassing the firewall
- Credentials are auto-generated and stored in `node.conf` (gitignored)
- All config files mounted read-only into containers
- All persistent data externalized to host volumes (`${STORAGE_PATH}/`)

## License

This project is licensed under the MIT License - see the LICENSE file for details.
