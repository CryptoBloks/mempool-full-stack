#!/usr/bin/env bash
# ==============================================================================
# test-config-pipeline.sh — End-to-end test for the config generation pipeline
#
# Validates: wizard.sh (non-interactive) -> node.conf -> generate-config.sh -> outputs
#
# Runs entirely locally — no Docker, no running services required.
# Creates an isolated temp workspace, copies the project, generates configs
# with known inputs, and validates all outputs.
#
# Usage:
#   ./tests/test-config-pipeline.sh
# ==============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ==============================================================================
# Temp workspace setup + cleanup trap
# ==============================================================================
WORK_DIR=""
cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mempool-test-pipeline.XXXXXX")"

echo "=== Config Pipeline Test ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Workspace:    ${WORK_DIR}"
echo ""

# Copy project to temp workspace, excluding .git and _tmp
# Use tar pipe to handle exclusions portably (rsync may not be installed)
tar -C "${PROJECT_ROOT}" \
    --exclude='.git' \
    --exclude='_tmp' \
    --exclude='node_modules' \
    -cf - . | tar -C "${WORK_DIR}" -xf -

# ==============================================================================
# Test harness
# ==============================================================================
PASS=0 FAIL=0 TOTAL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    ((TOTAL++)) || true
    if [[ "${expected}" == "${actual}" ]]; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s\n    expected: %s\n    actual:   %s\n' "${label}" "${expected}" "${actual}"
    fi
}

assert_file_exists() {
    local label="$1" filepath="$2"
    ((TOTAL++)) || true
    if [[ -f "${filepath}" ]]; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (file not found: %s)\n' "${label}" "${filepath}"
    fi
}

assert_file_not_exists() {
    local label="$1" filepath="$2"
    ((TOTAL++)) || true
    if [[ ! -f "${filepath}" ]]; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (file should not exist: %s)\n' "${label}" "${filepath}"
    fi
}

assert_file_contains() {
    local label="$1" filepath="$2" pattern="$3"
    ((TOTAL++)) || true
    if grep -qE -- "${pattern}" "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (pattern not found: %s)\n' "${label}" "${pattern}"
    fi
}

assert_file_not_contains() {
    local label="$1" filepath="$2" pattern="$3"
    ((TOTAL++)) || true
    if ! grep -qE -- "${pattern}" "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (pattern should not be present: %s)\n' "${label}" "${pattern}"
    fi
}

assert_valid_json() {
    local label="$1" filepath="$2"
    ((TOTAL++)) || true
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (invalid JSON)\n' "${label}"
    fi
}

assert_valid_yaml() {
    local label="$1" filepath="$2"
    ((TOTAL++)) || true
    # Try PyYAML first; fall back to basic structural checks if not installed
    if python3 -c "import yaml" 2>/dev/null; then
        if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${filepath}" 2>/dev/null; then
            ((PASS++)) || true
            printf '  \033[0;32m✓\033[0m %s\n' "${label}"
        else
            ((FAIL++)) || true
            printf '  \033[0;31m✗\033[0m %s (invalid YAML)\n' "${label}"
        fi
    else
        # Fallback: verify the file is non-empty and starts with valid YAML-ish content
        if [[ -s "${filepath}" ]] && head -1 "${filepath}" | grep -qE '^(#|---|\w)'; then
            ((PASS++)) || true
            printf '  \033[0;32m✓\033[0m %s (PyYAML not available — basic check only)\n' "${label}"
        else
            ((FAIL++)) || true
            printf '  \033[0;31m✗\033[0m %s (invalid YAML — basic check failed)\n' "${label}"
        fi
    fi
}

# assert_no_unreplaced_placeholders FILE
#   Checks that no {{PLACEHOLDER}} patterns remain in the file.
assert_no_unreplaced_placeholders() {
    local label="$1" filepath="$2"
    ((TOTAL++)) || true
    if ! grep -qE '\{\{[A-Z_]+\}\}' "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        local remaining
        remaining="$(grep -oE '\{\{[A-Z_]+\}\}' "${filepath}" | sort -u | tr '\n' ' ')"
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (unreplaced: %s)\n' "${label}" "${remaining}"
    fi
}

# ==============================================================================
# Helper: clean generated configs between scenarios (preserve templates)
# ==============================================================================
clean_generated_configs() {
    # Remove per-network config dirs
    rm -rf "${WORK_DIR}/config/mainnet" \
           "${WORK_DIR}/config/signet" \
           "${WORK_DIR}/config/testnet" \
           "${WORK_DIR}/config/mariadb" \
           "${WORK_DIR}/config/openresty" \
           "${WORK_DIR}/config/cloudflared" \
           "${WORK_DIR}/docker-compose.yml"
    # Remove UFW rules
    rm -f "${WORK_DIR}/config/ufw-rules.sh"
}

# ==============================================================================
# Scenario 1: Minimal config (mainnet only, no RPC, no tunnel, no TLS)
# ==============================================================================
echo ""
echo "=== Scenario 1: Minimal config (mainnet only, no RPC, no tunnel, no TLS) ==="

clean_generated_configs

cat > "${WORK_DIR}/node.conf" <<'NODECONF'
NETWORKS=mainnet
BITCOIN_MODE=docker-image
BITCOIN_VERSION=28.1
MEMPOOL_VERSION=3.1.0
ELECTRS_VERSION=latest
MARIADB_VERSION=10.11
OPENRESTY_VERSION=alpine
STORAGE_PATH=/data/mempool
BTRFS_ENABLED=false
TXINDEX=true
PRUNE=0
DBCACHE=2048
MAXMEMPOOL=300
MAXCONNECTIONS=40
RPC_ENDPOINT_ENABLED=false
WEB_PORT=80
TLS_MODE=none
DOMAIN_WEB=_
CLOUDFLARE_TUNNEL_ENABLED=false
UFW_ENABLED=true
BITCOIN_RPC_USER=testuser
BITCOIN_RPC_PASS=testpass123456789012345678901234
MARIADB_ROOT_PASS=rootpass1234567890123456789012
MARIADB_USER=mempool
MARIADB_PASS=dbpass12345678901234567890123456
NODECONF

# Run generate-config.sh in the temp workspace
echo "  Running generate-config.sh..."
(cd "${WORK_DIR}" && bash scripts/setup/generate-config.sh) >/dev/null 2>&1

echo ""
echo "  --- File existence checks ---"

assert_file_exists "bitcoin.conf exists" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf"
assert_file_exists "electrs.toml exists" \
    "${WORK_DIR}/config/mainnet/electrs.toml"
assert_file_exists "mempool-config.json exists" \
    "${WORK_DIR}/config/mainnet/mempool-config.json"
assert_file_exists "mariadb init SQL exists" \
    "${WORK_DIR}/config/mariadb/init/01-init.sql"
assert_file_exists "nginx.conf exists" \
    "${WORK_DIR}/config/openresty/nginx.conf"
assert_file_exists "ufw-rules.sh exists" \
    "${WORK_DIR}/config/ufw-rules.sh"
assert_file_exists "docker-compose.yml exists" \
    "${WORK_DIR}/docker-compose.yml"

echo ""
echo "  --- No unreplaced placeholders ---"

assert_no_unreplaced_placeholders "bitcoin.conf: no {{}} left" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf"
assert_no_unreplaced_placeholders "electrs.toml: no {{}} left" \
    "${WORK_DIR}/config/mainnet/electrs.toml"
assert_no_unreplaced_placeholders "mempool-config.json: no {{}} left" \
    "${WORK_DIR}/config/mainnet/mempool-config.json"
assert_no_unreplaced_placeholders "mariadb init SQL: no {{}} left" \
    "${WORK_DIR}/config/mariadb/init/01-init.sql"
assert_no_unreplaced_placeholders "nginx.conf: no {{}} left" \
    "${WORK_DIR}/config/openresty/nginx.conf"
assert_no_unreplaced_placeholders "ufw-rules.sh: no {{}} left" \
    "${WORK_DIR}/config/ufw-rules.sh"
assert_no_unreplaced_placeholders "docker-compose.yml: no {{}} left" \
    "${WORK_DIR}/docker-compose.yml"

echo ""
echo "  --- bitcoin.conf checks ---"

assert_file_contains "bitcoin.conf: server=1" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^server=1$"
assert_file_contains "bitcoin.conf: txindex=1 (boolean 'true' mapped to 1)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^txindex=1$"
assert_file_contains "bitcoin.conf: rpcallowip=172.20.0.0/24" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcallowip=172\.20\.0\.0/24$"
assert_file_contains "bitcoin.conf: rpcauth=testuser:" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcauth=testuser:"

# C1 BUG CHECK: rpcwhitelistdefault=0 is unconditionally present in the template.
# When RPC gateway is disabled, this blocks internal services (electrs/mempool)
# because the default whitelist becomes empty. This SHOULD NOT be present when
# RPC is disabled, but the template always includes it. If this test FAILS
# (i.e., the pattern IS found), it confirms bug C1 exists.
assert_file_not_contains "bitcoin.conf: C1 BUG — rpcwhitelistdefault=0 should not appear when RPC disabled" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcwhitelistdefault=0$"

assert_file_not_contains "bitcoin.conf: no signet=1 (mainnet only)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^signet=1$"
assert_file_not_contains "bitcoin.conf: no testnet=1 (mainnet only)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^testnet=1$"

echo ""
echo "  --- electrs.toml checks ---"

assert_file_contains "electrs.toml: daemon_rpc_addr points to bitcoind-mainnet" \
    "${WORK_DIR}/config/mainnet/electrs.toml" \
    'daemon_rpc_addr = "bitcoind-mainnet:'
assert_file_contains "electrs.toml: network = bitcoin (mainnet mapping)" \
    "${WORK_DIR}/config/mainnet/electrs.toml" \
    'network = "bitcoin"'
assert_file_contains "electrs.toml: auth = testuser:testpass" \
    "${WORK_DIR}/config/mainnet/electrs.toml" \
    'auth = "testuser:testpass'

echo ""
echo "  --- mempool-config.json checks ---"

assert_valid_json "mempool-config.json: valid JSON" \
    "${WORK_DIR}/config/mainnet/mempool-config.json"
assert_file_contains "mempool-config.json: HOST = bitcoind-mainnet" \
    "${WORK_DIR}/config/mainnet/mempool-config.json" \
    '"HOST": "bitcoind-mainnet"'
assert_file_contains "mempool-config.json: DATABASE = mempool" \
    "${WORK_DIR}/config/mainnet/mempool-config.json" \
    '"DATABASE": "mempool"'
assert_file_contains "mempool-config.json: USERNAME = testuser" \
    "${WORK_DIR}/config/mainnet/mempool-config.json" \
    '"USERNAME": "testuser"'
assert_file_contains "mempool-config.json: BACKEND = esplora" \
    "${WORK_DIR}/config/mainnet/mempool-config.json" \
    '"BACKEND": "esplora"'
assert_file_contains "mempool-config.json: ESPLORA REST_API_URL" \
    "${WORK_DIR}/config/mainnet/mempool-config.json" \
    '"REST_API_URL": "http://electrs-mainnet:3003"'

echo ""
echo "  --- docker-compose.yml checks ---"

assert_valid_yaml "docker-compose.yml: valid YAML" \
    "${WORK_DIR}/docker-compose.yml"
assert_file_contains "docker-compose.yml: bitcoind-mainnet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  bitcoind-mainnet:"
assert_file_contains "docker-compose.yml: electrs-mainnet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  electrs-mainnet:"
assert_file_contains "docker-compose.yml: mempool-api-mainnet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  mempool-api-mainnet:"
assert_file_contains "docker-compose.yml: mariadb service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  mariadb:"
assert_file_contains "docker-compose.yml: mempool-web service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  mempool-web:"
assert_file_contains "docker-compose.yml: openresty service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  openresty:"
assert_file_contains "docker-compose.yml: container_name: bitcoind-mainnet" \
    "${WORK_DIR}/docker-compose.yml" \
    "container_name: bitcoind-mainnet"
assert_file_contains "docker-compose.yml: container_name: electrs-mainnet" \
    "${WORK_DIR}/docker-compose.yml" \
    "container_name: electrs-mainnet"
assert_file_contains "docker-compose.yml: container_name: mariadb" \
    "${WORK_DIR}/docker-compose.yml" \
    "container_name: mariadb"
assert_file_contains "docker-compose.yml: container_name: openresty" \
    "${WORK_DIR}/docker-compose.yml" \
    "container_name: openresty"
assert_file_contains "docker-compose.yml: bitcoind healthcheck present" \
    "${WORK_DIR}/docker-compose.yml" \
    "bitcoin-cli.*getblockchaininfo"
assert_file_contains "docker-compose.yml: electrs --http-addr flag" \
    "${WORK_DIR}/docker-compose.yml" \
    -- "--http-addr"
assert_file_contains "docker-compose.yml: electrs exposes port 3003" \
    "${WORK_DIR}/docker-compose.yml" \
    '"3003"'
assert_file_contains "docker-compose.yml: electrs ulimits nofile" \
    "${WORK_DIR}/docker-compose.yml" \
    "nofile:"

# C6 BUG CHECK: The healthcheck for bitcoind should include -datadir=/data/.bitcoin
# so bitcoin-cli can find the cookie/config. Currently this is missing.
# If this test FAILS (pattern not found), it confirms bug C6 exists.
assert_file_contains "docker-compose.yml: C6 BUG — healthcheck should have -datadir=/data/.bitcoin" \
    "${WORK_DIR}/docker-compose.yml" \
    '-datadir=/data/\.bitcoin'

echo ""
echo "  --- nginx.conf checks ---"

assert_file_contains "nginx.conf: Docker DNS resolver for dynamic resolution" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "resolver 127.0.0.11 valid=30s"
assert_file_contains "nginx.conf: /api/v1 uses variable-based proxy_pass for backend" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    'set $backend_api http://mempool-api-mainnet:8999'
assert_file_contains "nginx.conf: /api/ uses variable-based proxy_pass for electrs" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    'set $backend_electrs http://electrs-mainnet:3003'
assert_file_contains "nginx.conf: /api/v1 location" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "location /api/v1"
assert_file_contains "nginx.conf: /api/ shorthand location" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "location /api/"
assert_file_not_contains "nginx.conf: no RPC location when RPC disabled" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "location ~ \^/v2/"
assert_file_contains "nginx.conf: server_name _" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "server_name _"

echo ""
echo "  --- MariaDB init SQL checks ---"

assert_file_contains "mariadb init: CREATE DATABASE IF NOT EXISTS" \
    "${WORK_DIR}/config/mariadb/init/01-init.sql" \
    "CREATE DATABASE IF NOT EXISTS"
assert_file_contains "mariadb init: mempool database" \
    "${WORK_DIR}/config/mariadb/init/01-init.sql" \
    "mempool"

echo ""
echo "  --- UFW rules checks ---"

assert_file_contains "ufw-rules.sh: allow ssh" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "ufw allow ssh"
assert_file_contains "ufw-rules.sh: default deny incoming" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "ufw default deny incoming"
assert_file_contains "ufw-rules.sh: allow 8333/tcp (mainnet P2P)" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "ufw allow 8333/tcp"
assert_file_contains "ufw-rules.sh: allow 80/tcp (web, no tunnel)" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "ufw allow 80/tcp"
assert_file_contains "ufw-rules.sh: DOCKER-USER chain" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "DOCKER-USER"
assert_file_contains "ufw-rules.sh: ufw_docker_fix function" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "ufw_docker_fix"

echo ""
echo "  --- RPC files should NOT exist (RPC disabled) ---"

assert_file_not_exists "jsonrpc-access.lua should not exist" \
    "${WORK_DIR}/config/openresty/jsonrpc-access.lua"
assert_file_not_exists "api-keys.json should not exist" \
    "${WORK_DIR}/config/openresty/api-keys.json"

echo ""
echo "  --- Cloudflared config should NOT exist (tunnel disabled) ---"

assert_file_not_exists "cloudflared config.yml should not exist" \
    "${WORK_DIR}/config/cloudflared/config.yml"


# ==============================================================================
# Scenario 2: Full config (mainnet+signet, RPC, tunnel, self-signed TLS)
# ==============================================================================
echo ""
echo "=== Scenario 2: Full config (mainnet+signet, RPC, tunnel, self-signed TLS) ==="

clean_generated_configs

cat > "${WORK_DIR}/node.conf" <<'NODECONF'
NETWORKS=mainnet,signet
BITCOIN_MODE=docker-image
BITCOIN_VERSION=28.1
MEMPOOL_VERSION=3.1.0
ELECTRS_VERSION=latest
MARIADB_VERSION=10.11
OPENRESTY_VERSION=alpine
STORAGE_PATH=/data/mempool
BTRFS_ENABLED=false
TXINDEX=true
PRUNE=0
DBCACHE=2048
MAXMEMPOOL=300
MAXCONNECTIONS=40
RPC_ENDPOINT_ENABLED=true
RPC_AUTH_MODE=api-key
RPC_API_KEY=mk_live_testapikey1234567890abcdef
RPC_METHOD_PROFILE=read-only
RPC_RATE_LIMIT=60
RPC_PORT=3000
GATEWAY_RPC_USER=gateway
GATEWAY_RPC_PASS=gatewaypass12345678901234567890
WEB_PORT=80
TLS_MODE=self-signed
DOMAIN_WEB=node.example.com
CLOUDFLARE_TUNNEL_ENABLED=true
CLOUDFLARE_TUNNEL_TOKEN=test-tunnel-token-abc
CF_HOSTNAME_WEB=mempool.example.com
CF_HOSTNAME_RPC=rpc.example.com
UFW_ENABLED=true
BITCOIN_RPC_USER=testuser
BITCOIN_RPC_PASS=testpass123456789012345678901234
MARIADB_ROOT_PASS=rootpass1234567890123456789012
MARIADB_USER=mempool
MARIADB_PASS=dbpass12345678901234567890123456
NODECONF

echo "  Running generate-config.sh..."
(cd "${WORK_DIR}" && bash scripts/setup/generate-config.sh) >/dev/null 2>&1

echo ""
echo "  --- Per-network files for mainnet AND signet ---"

assert_file_exists "mainnet bitcoin.conf exists" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf"
assert_file_exists "mainnet electrs.toml exists" \
    "${WORK_DIR}/config/mainnet/electrs.toml"
assert_file_exists "mainnet mempool-config.json exists" \
    "${WORK_DIR}/config/mainnet/mempool-config.json"
assert_file_exists "signet bitcoin.conf exists" \
    "${WORK_DIR}/config/signet/bitcoin.conf"
assert_file_exists "signet electrs.toml exists" \
    "${WORK_DIR}/config/signet/electrs.toml"
assert_file_exists "signet mempool-config.json exists" \
    "${WORK_DIR}/config/signet/mempool-config.json"

echo ""
echo "  --- No unreplaced placeholders (scenario 2) ---"

assert_no_unreplaced_placeholders "mainnet bitcoin.conf: no {{}} left" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf"
assert_no_unreplaced_placeholders "signet bitcoin.conf: no {{}} left" \
    "${WORK_DIR}/config/signet/bitcoin.conf"
assert_no_unreplaced_placeholders "signet electrs.toml: no {{}} left" \
    "${WORK_DIR}/config/signet/electrs.toml"
assert_no_unreplaced_placeholders "signet mempool-config.json: no {{}} left" \
    "${WORK_DIR}/config/signet/mempool-config.json"
assert_no_unreplaced_placeholders "docker-compose.yml: no {{}} left" \
    "${WORK_DIR}/docker-compose.yml"
assert_no_unreplaced_placeholders "nginx.conf: no {{}} left" \
    "${WORK_DIR}/config/openresty/nginx.conf"

echo ""
echo "  --- Signet-specific checks ---"

assert_file_contains "signet bitcoin.conf: signet=1" \
    "${WORK_DIR}/config/signet/bitcoin.conf" \
    "^signet=1$"
assert_file_contains "signet electrs.toml: daemon_rpc_addr = bitcoind-signet:38332" \
    "${WORK_DIR}/config/signet/electrs.toml" \
    'daemon_rpc_addr = "bitcoind-signet:38332"'
assert_file_contains "signet mempool-config.json: DATABASE = mempool_signet" \
    "${WORK_DIR}/config/signet/mempool-config.json" \
    '"DATABASE": "mempool_signet"'

echo ""
echo "  --- docker-compose.yml multi-network checks ---"

assert_file_contains "docker-compose.yml: bitcoind-mainnet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  bitcoind-mainnet:"
assert_file_contains "docker-compose.yml: bitcoind-signet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  bitcoind-signet:"
assert_file_contains "docker-compose.yml: electrs-signet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  electrs-signet:"
assert_file_contains "docker-compose.yml: mempool-api-signet service" \
    "${WORK_DIR}/docker-compose.yml" \
    "^  mempool-api-signet:"

echo ""
echo "  --- RPC files exist (RPC enabled) ---"

assert_file_exists "jsonrpc-access.lua exists" \
    "${WORK_DIR}/config/openresty/jsonrpc-access.lua"
assert_file_exists "api-keys.json exists" \
    "${WORK_DIR}/config/openresty/api-keys.json"

echo ""
echo "  --- api-keys.json checks ---"

assert_valid_json "api-keys.json: valid JSON" \
    "${WORK_DIR}/config/openresty/api-keys.json"
assert_file_contains "api-keys.json: contains API key" \
    "${WORK_DIR}/config/openresty/api-keys.json" \
    "mk_live_testapikey1234567890abcdef"

echo ""
echo "  --- Lua script checks ---"

assert_file_contains "jsonrpc-access.lua: whitelisted_methods table" \
    "${WORK_DIR}/config/openresty/jsonrpc-access.lua" \
    "whitelisted_methods"

echo ""
echo "  --- nginx.conf RPC checks ---"

assert_file_contains "nginx.conf: RPC location block /v2/" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "/v2/"

echo ""
echo "  --- bitcoin.conf RPC gateway checks (mainnet) ---"

assert_file_contains "bitcoin.conf mainnet: rpcauth=testuser: (internal)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcauth=testuser:"
assert_file_contains "bitcoin.conf mainnet: rpcauth=gateway: (gateway)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcauth=gateway:"
assert_file_contains "bitcoin.conf mainnet: rpcwhitelist=gateway: (method whitelist)" \
    "${WORK_DIR}/config/mainnet/bitcoin.conf" \
    "^rpcwhitelist=gateway:"

echo ""
echo "  --- Cloudflared config checks ---"

assert_file_exists "cloudflared config.yml exists" \
    "${WORK_DIR}/config/cloudflared/config.yml"
assert_file_contains "cloudflared: mempool.example.com hostname" \
    "${WORK_DIR}/config/cloudflared/config.yml" \
    "mempool\\.example\\.com"
assert_file_contains "cloudflared: rpc.example.com hostname" \
    "${WORK_DIR}/config/cloudflared/config.yml" \
    "rpc\\.example\\.com"

echo ""
echo "  --- UFW rules tunnel-mode checks ---"

assert_file_not_contains "ufw-rules.sh: no 'ufw allow 80/tcp' (tunnel mode)" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "^ufw allow 80/tcp"
assert_file_not_contains "ufw-rules.sh: no 'ufw allow 3000/tcp' (tunnel mode)" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "^ufw allow 3000/tcp"
assert_file_contains "ufw-rules.sh: Cloudflare Tunnel comment" \
    "${WORK_DIR}/config/ufw-rules.sh" \
    "Cloudflare Tunnel"

echo ""
echo "  --- TLS checks ---"

assert_file_contains "nginx.conf: listen 443 ssl (self-signed)" \
    "${WORK_DIR}/config/openresty/nginx.conf" \
    "listen 443 ssl"


# ==============================================================================
# Scenario 3: Wizard key consumption audit
# ==============================================================================
echo ""
echo "=== Scenario 3: Wizard key consumption audit ==="

# Extract keys written by wizard (wiz_set calls)
wizard_keys=$(grep -oP 'wiz_set\s+\K[A-Z_]+' "${WORK_DIR}/scripts/setup/wizard.sh" | sort -u)

# Extract keys read by generator (get_config calls)
generator_keys=$(grep -oP 'get_config\s+\K[A-Z_]+' "${WORK_DIR}/scripts/setup/generate-config.sh" | sort -u)

# Extract keys read by any script in scripts/ (get_config calls)
all_script_keys=$(grep -rhoP 'get_config\s+\K[A-Z_]+' "${WORK_DIR}/scripts/" | sort -u)

# Find orphaned keys (written but never read anywhere)
orphaned=0
while IFS= read -r key; do
    if ! echo "${all_script_keys}" | grep -qx "${key}"; then
        ((FAIL++)) || true
        ((TOTAL++)) || true
        ((orphaned++)) || true
        printf '  \033[0;31m✗\033[0m Orphaned key: %s (written by wizard, never read)\n' "${key}"
    fi
done <<< "${wizard_keys}"

if [[ ${orphaned} -eq 0 ]]; then
    ((PASS++)) || true
    ((TOTAL++)) || true
    printf '  \033[0;32m✓\033[0m All wizard keys are consumed by at least one script\n'
fi

# Note: Some orphaned keys are expected at this stage due to known bugs:
#   - BITCOIN_MODE (C2 bug: wizard writes it, generator ignores it)
#   - BITCOIN_EXT_RPC_HOST/PORT/USER/PASS (C2 bug: external mode unimplemented)
#   - RPC_AUTH_MODE (C3 bug: wizard writes it, Lua ignores it)
#   - LETSENCRYPT_EMAIL (M1: dead config key)
#   - DOMAIN_RPC (M1: dead config key)
# These are documented in _tmp/V2-audit-findings.md


# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=================================="
echo "Results: ${TOTAL} tests, ${PASS} passed, ${FAIL} failed"
echo "=================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
