#!/usr/bin/env bash
# ==============================================================================
# prune.sh — Prune old BTRFS snapshots, keeping the N most recent per component
#
# Usage:
#   ./scripts/snapshot/prune.sh            # use BACKUP_RETENTION from config (default 7)
#   ./scripts/snapshot/prune.sh --keep 3   # keep 3 most recent per component
# ==============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_SCRIPT_DIR}/../lib/config-utils.sh"

# ==============================================================================
# Parse arguments
# ==============================================================================
KEEP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP="${2:?--keep requires a value}"
            shift 2
            ;;
        --keep=*)
            KEEP="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--keep N]"
            echo ""
            echo "Options:"
            echo "  --keep N    Keep N most recent snapshots per component (default: BACKUP_RETENTION or 7)"
            echo "  -h, --help  Show this help"
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

# Determine retention count
if [[ -z "${KEEP}" ]]; then
    KEEP="$(get_config BACKUP_RETENTION "7")"
fi

if [[ ! "${KEEP}" =~ ^[0-9]+$ ]] || [[ "${KEEP}" -lt 1 ]]; then
    log_error "Invalid --keep value: ${KEEP}. Must be a positive integer."
    exit 1
fi

if [[ ! -d "${SNAPSHOT_DIR}" ]]; then
    log_info "No snapshots directory found. Nothing to prune."
    exit 0
fi

# ==============================================================================
# Group snapshots by component prefix and prune each group
# ==============================================================================
log_header "Pruning Snapshots (keeping ${KEEP} per component)"

# Collect all snapshot directory names
declare -A COMPONENT_SNAPS

for snap_path in "${SNAPSHOT_DIR}"/*/; do
    [[ -d "${snap_path}" ]] || continue
    snap_name="$(basename "${snap_path}")"

    # Extract component prefix: everything before the timestamp
    # Timestamps are YYYYMMDD_HHMMSS (15 chars)
    if [[ "${snap_name}" =~ ^(.+)-([0-9]{8}_[0-9]{6})$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        # Append to component group (newline-separated for sorting)
        if [[ -n "${COMPONENT_SNAPS[${prefix}]:-}" ]]; then
            COMPONENT_SNAPS["${prefix}"]="${COMPONENT_SNAPS[${prefix}]}"$'\n'"${snap_name}"
        else
            COMPONENT_SNAPS["${prefix}"]="${snap_name}"
        fi
    else
        log_warn "Skipping unrecognized snapshot: ${snap_name}"
    fi
done

DELETED=0

for prefix in "${!COMPONENT_SNAPS[@]}"; do
    # Sort snapshots newest first (lexicographic sort on timestamp works)
    mapfile -t sorted < <(echo "${COMPONENT_SNAPS[${prefix}]}" | sort -r)

    count=${#sorted[@]}
    if [[ ${count} -le ${KEEP} ]]; then
        log_info "${prefix}: ${count} snapshot(s), keeping all"
        continue
    fi

    to_delete=$((count - KEEP))
    log_info "${prefix}: ${count} snapshot(s), pruning ${to_delete}"

    # Delete the oldest (those beyond KEEP)
    for (( i=KEEP; i<count; i++ )); do
        snap="${sorted[$i]}"
        snap_path="${SNAPSHOT_DIR}/${snap}"

        log_info "  Deleting: ${snap}"
        if btrfs subvolume delete "${snap_path}" 2>/dev/null; then
            DELETED=$((DELETED + 1))
        else
            # Fallback: try removing as regular directory if not a subvolume
            if rm -rf "${snap_path}" 2>/dev/null; then
                DELETED=$((DELETED + 1))
            else
                log_error "  Failed to delete: ${snap}"
            fi
        fi
    done
done

log_success "Pruning complete. Deleted ${DELETED} snapshot(s)."
