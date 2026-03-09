#!/usr/bin/env bash
# ==============================================================================
# health-check.sh — Check health of all mempool.space stack services
#
# Usage:
#   ./scripts/maintenance/health-check.sh
#
# Exit code: 0 = all healthy, 1 = issues found
# ==============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_SCRIPT_DIR}/../lib/config-utils.sh"
# shellcheck source=../lib/network-defaults.sh
source "${_SCRIPT_DIR}/../lib/network-defaults.sh"

# ==============================================================================
# Parse arguments
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $0"
            echo ""
            echo "Checks all containers, sync progress, database, disk space, and Electrs."
            echo "Exit code: 0 = healthy, 1 = issues found"
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# Setup
# ==============================================================================
require_command docker "apt install docker.io"

if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found."
    exit 1
fi

load_config

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"
ISSUES=0

log_header "Health Check"

# ==============================================================================
# Check: All containers running
# ==============================================================================
log_info "Checking container status..."
cd "${PROJECT_ROOT}"

# Get expected services from docker-compose
mapfile -t expected_services < <(docker compose config --services 2>/dev/null)

for svc in "${expected_services[@]}"; do
    [[ -z "${svc}" ]] && continue

    status=$(docker compose ps --status running --format "{{.Name}}" 2>/dev/null | grep -c "^${svc}$") || true

    if [[ "${status}" -ge 1 ]]; then
        log_success "Container ${svc}: running"
    else
        log_error "Container ${svc}: NOT running"
        ISSUES=$((ISSUES + 1))
    fi
done

# ==============================================================================
# Check: Bitcoin Core sync progress per network
# ==============================================================================
log_info "Checking Bitcoin Core sync status..."

mapfile -t nets < <(get_networks)

rpc_user="$(get_config BITCOIN_RPC_USER "mempool")"
rpc_pass="$(get_config BITCOIN_RPC_PASS "")"

for net in "${nets[@]}"; do
    container="bitcoind-${net}"

    # Skip if not running
    if ! docker compose ps --status running --format "{{.Name}}" 2>/dev/null | grep -q "^${container}$"; then
        continue
    fi

    if [[ -z "${rpc_pass}" ]]; then
        log_warn "${container}: no RPC password configured, skipping"
        continue
    fi

    if info=$(docker compose exec -T "${container}" bitcoin-cli \
        -rpcuser="${rpc_user}" -rpcpassword="${rpc_pass}" \
        getblockchaininfo 2>/dev/null); then

        progress=$(echo "${info}" | grep -o '"verificationprogress"[[:space:]]*:[[:space:]]*[0-9.e-]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
        blocks=$(echo "${info}" | grep -o '"blocks"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
        headers=$(echo "${info}" | grep -o '"headers"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')

        if [[ -n "${progress}" ]]; then
            pct=$(awk "BEGIN { printf \"%.2f\", ${progress} * 100 }")
            if awk "BEGIN { exit (${progress} >= 0.999) ? 0 : 1 }"; then
                log_success "${container}: synced (blocks=${blocks:-0}, progress=${pct}%)"
            else
                log_warn "${container}: syncing (blocks=${blocks:-0}/${headers:-0}, progress=${pct}%)"
                ISSUES=$((ISSUES + 1))
            fi
        fi
    else
        log_error "${container}: unable to query RPC"
        ISSUES=$((ISSUES + 1))
    fi
done

# ==============================================================================
# Check: MariaDB connectivity
# ==============================================================================
log_info "Checking MariaDB connectivity..."

if docker compose ps --status running --format "{{.Name}}" 2>/dev/null | grep -q "^mariadb$"; then
    MYSQL_ROOT_PASS="$(get_config MARIADB_ROOT_PASSWORD "")"
    MYSQL_USER="$(get_config MARIADB_USER "mempool")"
    MYSQL_PASS="$(get_config MARIADB_PASSWORD "")"

    # Try connecting with the application user
    if [[ -n "${MYSQL_PASS}" ]]; then
        if docker compose exec -T mariadb mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB: responsive (user=${MYSQL_USER})"
        else
            log_error "MariaDB: connection failed (user=${MYSQL_USER})"
            ISSUES=$((ISSUES + 1))
        fi
    elif [[ -n "${MYSQL_ROOT_PASS}" ]]; then
        if docker compose exec -T mariadb mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" &>/dev/null; then
            log_success "MariaDB: responsive (root)"
        else
            log_error "MariaDB: connection failed"
            ISSUES=$((ISSUES + 1))
        fi
    else
        log_warn "MariaDB: no password configured, skipping connectivity check"
    fi
else
    log_error "MariaDB: NOT running"
    ISSUES=$((ISSUES + 1))
fi

# ==============================================================================
# Check: Disk space
# ==============================================================================
log_info "Checking disk space..."

if [[ -d "${STORAGE_PATH}" ]]; then
    avail_gb=$(df -BG "${STORAGE_PATH}" | awk 'NR==2 { gsub(/G/, "", $4); print $4 }')
    use_pct=$(df "${STORAGE_PATH}" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')

    if [[ "${avail_gb}" -lt 10 ]]; then
        log_error "Disk space: ${avail_gb}G available (${use_pct}% used) - CRITICAL"
        ISSUES=$((ISSUES + 1))
    elif [[ "${avail_gb}" -lt 50 ]]; then
        log_warn "Disk space: ${avail_gb}G available (${use_pct}% used) - LOW"
        ISSUES=$((ISSUES + 1))
    else
        log_success "Disk space: ${avail_gb}G available (${use_pct}% used)"
    fi
else
    log_warn "Storage path ${STORAGE_PATH} does not exist."
fi

# ==============================================================================
# Check: Electrs connectivity per network
# ==============================================================================
log_info "Checking Electrs connectivity..."

for net in "${nets[@]}"; do
    container="electrs-${net}"

    if ! docker compose ps --status running --format "{{.Name}}" 2>/dev/null | grep -q "^${container}$"; then
        continue
    fi

    # Check if Electrs TCP port is listening (port 50001 inside container)
    if docker compose exec -T "${container}" sh -c 'echo | nc -w 2 localhost 50001' &>/dev/null; then
        log_success "${container}: listening on port 50001"
    else
        # Electrs may not have nc; try a different approach
        if docker compose exec -T "${container}" sh -c 'cat < /dev/tcp/localhost/50001' &>/dev/null 2>&1; then
            log_success "${container}: listening on port 50001"
        else
            log_warn "${container}: port 50001 not responsive (may still be indexing)"
            ISSUES=$((ISSUES + 1))
        fi
    fi
done

# ==============================================================================
# Summary
# ==============================================================================
echo ""
if [[ ${ISSUES} -eq 0 ]]; then
    log_success "All checks passed. System is healthy."
    exit 0
else
    log_warn "${ISSUES} issue(s) found."
    exit 1
fi
