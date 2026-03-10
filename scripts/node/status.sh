#!/usr/bin/env bash
# ==============================================================================
# status.sh — Show status of mempool.space Docker stack
#
# Usage:
#   ./scripts/node/status.sh
#
# Shows container status, Bitcoin Core sync progress, disk usage, and uptime.
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
            echo "Shows container status, Bitcoin Core sync progress, disk usage, and uptime."
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

require_command docker "apt install docker.io"

if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found."
    exit 1
fi

load_config

# ==============================================================================
# Container status
# ==============================================================================
cd "${PROJECT_ROOT}"

log_header "Container Status"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker compose ps

# ==============================================================================
# Bitcoin Core sync status per network
# ==============================================================================
log_header "Bitcoin Core Sync Status"

mapfile -t nets < <(get_networks)
if [[ ${#nets[@]} -eq 0 ]]; then
    log_warn "No networks configured."
else
    for net in "${nets[@]}"; do
        local_container="bitcoind-${net}"

        # Check if container is running
        if ! docker compose ps --status running --format "{{.Name}}" 2>/dev/null | grep -q "^${local_container}$"; then
            log_warn "${local_container}: not running"
            continue
        fi

        # Get RPC credentials
        rpc_user="$(get_config BITCOIN_RPC_USER "mempool")"
        rpc_pass="$(get_config BITCOIN_RPC_PASS "")"

        if [[ -z "${rpc_pass}" ]]; then
            log_warn "${local_container}: no RPC password configured, skipping sync check"
            continue
        fi

        # Query blockchain info via bitcoin-cli inside the container
        if info=$(docker compose exec -T "${local_container}" bitcoin-cli \
            -rpcuser="${rpc_user}" -rpcpassword="${rpc_pass}" \
            getblockchaininfo 2>/dev/null); then

            chain=$(echo "${info}" | grep -o '"chain"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
            blocks=$(echo "${info}" | grep -o '"blocks"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
            headers=$(echo "${info}" | grep -o '"headers"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
            progress=$(echo "${info}" | grep -o '"verificationprogress"[[:space:]]*:[[:space:]]*[0-9.e-]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')

            # Format progress as percentage
            if [[ -n "${progress}" ]]; then
                pct=$(awk "BEGIN { printf \"%.4f\", ${progress} * 100 }")
            else
                pct="unknown"
            fi

            printf "  %-12s chain=%-8s blocks=%-8s headers=%-8s progress=%s%%\n" \
                "${net}:" "${chain:-unknown}" "${blocks:-0}" "${headers:-0}" "${pct}"
        else
            log_warn "${local_container}: unable to query blockchain info"
        fi
    done
fi

# ==============================================================================
# Disk usage
# ==============================================================================
log_header "Disk Usage"

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"

if [[ -d "${STORAGE_PATH}" ]]; then
    log_info "Storage path: ${STORAGE_PATH}"
    # Show top-level directory sizes
    du -sh "${STORAGE_PATH}"/*/ 2>/dev/null | sort -rh || log_warn "No data directories found."

    # Show filesystem usage
    echo ""
    df -h "${STORAGE_PATH}" | head -2
else
    log_warn "Storage path ${STORAGE_PATH} does not exist."
fi

# ==============================================================================
# Uptime
# ==============================================================================
log_header "System Uptime"
uptime
