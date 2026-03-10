# Changelog

All notable changes to this project are documented in this file.

---

## [2.0.0] — 2026-03-09

Complete rewrite from a static Docker Compose stack into a configurator-driven, self-hosted Bitcoin infrastructure platform.

### Added

**Phase 1: Foundation** (`381e2a0`)
- Shared libraries: `common.sh` (logging, prompts, validators), `config-utils.sh` (node.conf read/write), `network-defaults.sh` (per-network defaults, Docker images)
- Template system with 9 `.tmpl` files using `{{PLACEHOLDER}}` syntax
- `generate-config.sh` — core config generator that renders all service configs from `node.conf`
- `validate-config.sh` — end-to-end config validator (45+ checks)

**Phase 2: Wizard** (`fe775a1`)
- `wizard.sh` — interactive 11-section configurator
  - Network selection (mainnet, signet, testnet)
  - Bitcoin Core source (docker-image / build / external)
  - Application version selection with GitHub API fetch
  - Storage path configuration with BTRFS detection
  - Bitcoin Core options (txindex, pruning, cache)
  - RPC web endpoint (API key auth, rate limiting, method profiles)
  - Port configuration with conflict detection
  - SSL/TLS (none / self-signed / Let's Encrypt)
  - Cloudflare Tunnel integration
  - UFW firewall configuration
  - Credential auto-generation
- `--non-interactive` mode for CI/scripted deployments
- `--skip-generate` flag to skip config generation
- Re-run support with existing `node.conf` (pre-fills defaults)

**Phase 3: Docker Stack** (`a0e3a34`)
- Per-network containers: `bitcoind-{net}`, `electrs-{net}`, `mempool-api-{net}`
- Shared services: `mariadb`, `mempool-web`, `openresty`
- Container security hardening (`no-new-privileges`, capability dropping)
- Health checks for all services
- Docker bridge network `mempool_net` (172.20.0.0/24)

**Phase 4: RPC Gateway** (`760e45d`)
- Lua-based JSON-RPC filtering with `lua-resty-limit-req` rate limiting
- Path-based API key support (`/v1/{key}[/{network}]`)
- Header-based API key support (`X-API-Key`)
- Per-network RPC routing (mainnet/signet/testnet)
- Method whitelist profiles (read-only / standard / full)
- CORS configuration with OPTIONS preflight support
- JSON-RPC 2.0 compliant error responses
- API key management scripts: `add-key.sh`, `list-keys.sh`, `revoke-key.sh`, `test-endpoint.sh`

**Phase 5: Firewall, SSL & Remote Access** (`d5937e7`)
- Docker-aware UFW rules (DOCKER-USER iptables chain)
- Tunnel-aware firewall logic (web/RPC ports skipped when tunnel is enabled)
- `generate-self-signed.sh` — 2048-bit RSA with SAN support
- `setup-letsencrypt.sh` — certbot/acme.sh with auto-renewal
- `setup-tunnel.sh` — interactive Cloudflare Tunnel wizard

**Phase 6: Backup & Operations** (`0965b05`)
- Node management: `start.sh`, `stop.sh`, `restart.sh`, `status.sh`, `logs.sh`
- BTRFS snapshot management: `create.sh`, `list.sh`, `prune.sh`
- S3 backup: `full-backup.sh` (orchestrated stop/snapshot/restart/upload)
- S3 streaming: `s3-push.sh`, `s3-pull.sh` (tar | zstd | rclone, no temp files)
- S3 management: `s3-list.sh`, `s3-prune.sh` (retention enforcement)
- `restore.sh` — S3 or local, full or component-level, with permission fix
- `health-check.sh` — container, sync, MariaDB, disk, and Electrs checks
- `update.sh` — GitHub API version check with config rollback on failure

**Post-implementation fixes** (`fdd7dc9`, `eb4769c`)
- Resolved design questions: global electrs, mempool/bitcoin default image, idempotent MariaDB init
- Fixed critical bugs: `local` outside function in `start.sh`, wrong Cloudflare config key
- Added config rollback to `update.sh`
- Rewrote Dockerfiles for Ubuntu 24.04 compatibility
- Removed 6 unused functions, added UFW port deduplication, value whitespace trimming

### Removed
- V1 static `docker-compose.yml`
- V1 build scripts (`setup.sh`, `build.sh`)
- V1 Dockerfiles (`Dockerfile.mariadb`, `Dockerfile.mempool`)
- V1 static configs (`config/bitcoin/`, `config/fulcrum/`, `config/mempool/`, `config/mariadb/my.cnf`)

### Changed
- `Dockerfile.bitcoin` moved to `docker/` and rewritten for binary download with configurable version
- `Dockerfile.fulcrum` moved to `docker/` and rewritten with Qt6/cmake for Ubuntu 24.04
- `.gitignore` updated for generated files and per-network config directories

---

## [1.0.0] — Initial Release

Static Docker Compose setup with:
- Bitcoin Core 25.0
- Fulcrum 1.9.0 (Electrum server)
- MariaDB 10.6
- Mempool.space 2.3.0
- Custom Dockerfiles building from source on Ubuntu 24.04
- Static configuration files
- `setup.sh` and `build.sh` scripts
