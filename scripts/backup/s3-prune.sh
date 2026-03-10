#!/usr/bin/env bash
# ==============================================================================
# s3-prune.sh — Enforce retention on remote S3 backups
#
# Usage:
#   ./scripts/backup/s3-prune.sh                              # use BACKUP_RETENTION, all networks
#   ./scripts/backup/s3-prune.sh --keep 5                     # keep 5 most recent
#   ./scripts/backup/s3-prune.sh --keep 3 --network mainnet   # prune mainnet only
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
KEEP=""
NETWORK=""

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
        --network)
            NETWORK="${2:?--network requires a value}"
            shift 2
            ;;
        --network=*)
            NETWORK="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--keep N] [--network NETWORK]"
            echo ""
            echo "Options:"
            echo "  --keep N            Keep N most recent backups per network (default: BACKUP_RETENTION or 7)"
            echo "  --network NETWORK   Prune only this network's backups"
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
require_command rclone "curl https://rclone.org/install.sh | sudo bash"

load_config

S3_REMOTE="$(get_config S3_REMOTE "")"
S3_BUCKET="$(get_config S3_BUCKET "")"
S3_PREFIX="$(get_config S3_PREFIX "")"

if [[ -z "${S3_REMOTE}" || -z "${S3_BUCKET}" ]]; then
    log_error "S3_REMOTE and S3_BUCKET must be set in node.conf"
    exit 1
fi

# Determine retention count
if [[ -z "${KEEP}" ]]; then
    KEEP="$(get_config BACKUP_RETENTION "7")"
fi

if [[ ! "${KEEP}" =~ ^[0-9]+$ ]] || [[ "${KEEP}" -lt 1 ]]; then
    log_error "Invalid --keep value: ${KEEP}. Must be a positive integer."
    exit 1
fi

if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
fi

# ==============================================================================
# Prune
# ==============================================================================
log_header "S3 Backup Pruning (keeping ${KEEP} per network)"

REMOTE_BASE="${S3_REMOTE}:${S3_BUCKET}/${S3_PREFIX}backups"

# Determine which networks to prune
if [[ -n "${NETWORK}" ]]; then
    NETWORKS=("${NETWORK}")
else
    mapfile -t NETWORKS < <(get_networks)
    if [[ ${#NETWORKS[@]} -eq 0 ]]; then
        NETWORKS=("mainnet" "signet" "testnet")
    fi
fi

TOTAL_DELETED=0

for net in "${NETWORKS[@]}"; do
    NET_PATH="${REMOTE_BASE}/${net}"

    # List backup IDs sorted newest first
    mapfile -t backup_ids < <(rclone lsd "${NET_PATH}/" 2>/dev/null | awk '{print $NF}' | sort -r)

    count=${#backup_ids[@]}
    if [[ ${count} -eq 0 ]]; then
        continue
    fi

    if [[ ${count} -le ${KEEP} ]]; then
        log_info "${net}: ${count} backup(s), keeping all"
        continue
    fi

    to_delete=$((count - KEEP))
    log_info "${net}: ${count} backup(s), pruning ${to_delete}"

    # Delete the oldest backups (those beyond KEEP)
    for (( i=KEEP; i<count; i++ )); do
        bid="${backup_ids[$i]}"
        [[ -z "${bid}" ]] && continue

        delete_path="${NET_PATH}/${bid}"
        log_info "  Deleting: ${bid}"

        if rclone purge "${delete_path}" 2>/dev/null; then
            TOTAL_DELETED=$((TOTAL_DELETED + 1))
            log_success "  Deleted: ${bid}"
        else
            log_error "  Failed to delete: ${bid}"
        fi
    done
done

log_success "S3 pruning complete. Deleted ${TOTAL_DELETED} backup(s)."
