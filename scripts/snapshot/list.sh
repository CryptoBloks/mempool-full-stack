#!/usr/bin/env bash
# ==============================================================================
# list.sh — List local BTRFS snapshots
#
# Usage:
#   ./scripts/snapshot/list.sh                    # list all snapshots
#   ./scripts/snapshot/list.sh --network mainnet  # list mainnet snapshots only
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
        -h|--help)
            echo "Usage: $0 [--network NETWORK]"
            echo ""
            echo "Options:"
            echo "  --network NETWORK   List only snapshots for this network"
            echo "  -h, --help          Show this help"
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
load_config

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"
SNAPSHOT_DIR="${STORAGE_PATH}/snapshots"

if [[ ! -d "${SNAPSHOT_DIR}" ]]; then
    log_info "No snapshots directory found at ${SNAPSHOT_DIR}"
    exit 0
fi

if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
fi

# ==============================================================================
# List snapshots
# ==============================================================================
log_header "Local BTRFS Snapshots"

printf "%-45s  %-20s  %s\n" "NAME" "DATE" "SIZE"
printf "%-45s  %-20s  %s\n" "----" "----" "----"

FOUND=0

# List snapshot directories, sorted by name (newest first due to timestamp in name)
while IFS= read -r snap_path; do
    [[ -z "${snap_path}" ]] && continue
    snap_name="$(basename "${snap_path}")"

    # Filter by network if specified
    if [[ -n "${NETWORK}" ]]; then
        if [[ "${snap_name}" != *"-${NETWORK}-"* ]]; then
            continue
        fi
    fi

    # Extract date from snapshot name (last part: YYYYMMDD_HHMMSS)
    if [[ "${snap_name}" =~ ([0-9]{8}_[0-9]{6})$ ]]; then
        raw_date="${BASH_REMATCH[1]}"
        # Format: YYYY-MM-DD HH:MM:SS
        formatted_date="${raw_date:0:4}-${raw_date:4:2}-${raw_date:6:2} ${raw_date:9:2}:${raw_date:11:2}:${raw_date:13:2}"
    else
        formatted_date="unknown"
    fi

    # Get size (du for actual disk usage)
    size="$(du -sh "${snap_path}" 2>/dev/null | awk '{print $1}')" || size="unknown"

    printf "%-45s  %-20s  %s\n" "${snap_name}" "${formatted_date}" "${size}"
    FOUND=$((FOUND + 1))

done < <(ls -1dr "${SNAPSHOT_DIR}"/*/ 2>/dev/null || true)

if [[ ${FOUND} -eq 0 ]]; then
    if [[ -n "${NETWORK}" ]]; then
        log_info "No snapshots found for network '${NETWORK}'."
    else
        log_info "No snapshots found."
    fi
else
    echo ""
    log_info "Total: ${FOUND} snapshot(s)"
fi
