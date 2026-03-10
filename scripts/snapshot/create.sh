#!/usr/bin/env bash
# ==============================================================================
# create.sh — Create BTRFS snapshots of mempool.space data
#
# Usage:
#   ./scripts/snapshot/create.sh                              # all components, all networks
#   ./scripts/snapshot/create.sh --network mainnet            # all components for mainnet
#   ./scripts/snapshot/create.sh --component bitcoin          # bitcoin for all networks
#   ./scripts/snapshot/create.sh --network mainnet --component bitcoin
#
# Snapshots are stored in ${STORAGE_PATH}/snapshots/
# Naming: {component}-{network}-{YYYYMMDD_HHMMSS}  (or {component}-{YYYYMMDD_HHMMSS} for shared)
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
NETWORK=""
COMPONENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)
            NETWORK="${2:?--network requires a value}"
            shift 2
            ;;
        --network=*)
            NETWORK="${1#*=}"
            shift
            ;;
        --component)
            COMPONENT="${2:?--component requires a value}"
            shift 2
            ;;
        --component=*)
            COMPONENT="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--network NETWORK] [--component COMPONENT]"
            echo ""
            echo "Options:"
            echo "  --network NETWORK       Snapshot only this network's data"
            echo "  --component COMPONENT   Snapshot only this component (bitcoin, electrs, mempool, mariadb)"
            echo "  -h, --help              Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# Validate
# ==============================================================================
require_command btrfs "apt install btrfs-progs"

load_config

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"
SNAPSHOT_DIR="${STORAGE_PATH}/snapshots"

# Verify BTRFS filesystem
if ! stat -f -c %T "${STORAGE_PATH}" 2>/dev/null | grep -q btrfs; then
    log_error "Storage path ${STORAGE_PATH} is not on a BTRFS filesystem."
    log_error "BTRFS snapshots require a BTRFS filesystem. Cannot proceed."
    exit 1
fi

if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
fi

if [[ -n "${COMPONENT}" ]]; then
    case "${COMPONENT}" in
        bitcoin|electrs|mempool|mariadb) ;;
        *)
            log_error "Invalid component: ${COMPONENT}. Must be one of: bitcoin, electrs, mempool, mariadb"
            exit 1
            ;;
    esac
fi

# ==============================================================================
# Build list of subvolumes to snapshot
# ==============================================================================
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
declare -a SNAPSHOT_TARGETS=()

# Build network list
if [[ -n "${NETWORK}" ]]; then
    NETWORKS=("${NETWORK}")
else
    mapfile -t NETWORKS < <(get_networks)
fi

# Per-network components
NETWORK_COMPONENTS=("bitcoin" "electrs" "mempool")

for net in "${NETWORKS[@]}"; do
    for comp in "${NETWORK_COMPONENTS[@]}"; do
        # Skip if component filter is set and doesn't match
        if [[ -n "${COMPONENT}" && "${COMPONENT}" != "${comp}" ]]; then
            continue
        fi

        src="${STORAGE_PATH}/${net}/${comp}"
        if [[ -d "${src}" ]]; then
            snap_name="${comp}-${net}-${TIMESTAMP}"
            SNAPSHOT_TARGETS+=("${src}|${snap_name}")
        fi
    done
done

# Shared components (mariadb)
if [[ -z "${COMPONENT}" || "${COMPONENT}" == "mariadb" ]]; then
    src="${STORAGE_PATH}/mariadb"
    if [[ -d "${src}" ]]; then
        snap_name="mariadb-${TIMESTAMP}"
        SNAPSHOT_TARGETS+=("${src}|${snap_name}")
    fi
fi

if [[ ${#SNAPSHOT_TARGETS[@]} -eq 0 ]]; then
    log_warn "No data directories found to snapshot."
    exit 0
fi

# ==============================================================================
# Create snapshots
# ==============================================================================
log_header "Creating BTRFS Snapshots"

mkdir -p "${SNAPSHOT_DIR}"

CREATED=0
for target in "${SNAPSHOT_TARGETS[@]}"; do
    src="${target%%|*}"
    snap_name="${target##*|}"
    dest="${SNAPSHOT_DIR}/${snap_name}"

    log_info "Snapshotting ${src} -> ${dest}"
    if btrfs subvolume snapshot -r "${src}" "${dest}"; then
        log_success "Created: ${snap_name}"
        CREATED=$((CREATED + 1))
    else
        log_error "Failed to snapshot: ${src}"
    fi
done

log_success "Created ${CREATED} snapshot(s) in ${SNAPSHOT_DIR}"
