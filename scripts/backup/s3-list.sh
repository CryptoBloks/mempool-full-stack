#!/usr/bin/env bash
# ==============================================================================
# s3-list.sh — List remote S3 backups
#
# Usage:
#   ./scripts/backup/s3-list.sh                    # list all backups
#   ./scripts/backup/s3-list.sh --network mainnet  # list mainnet backups only
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
            echo "  --network NETWORK   List backups for this network only"
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

if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
fi

# ==============================================================================
# List backups
# ==============================================================================
log_header "Remote S3 Backups"

REMOTE_BASE="${S3_REMOTE}:${S3_BUCKET}/${S3_PREFIX}backups"

# Determine which networks to list
if [[ -n "${NETWORK}" ]]; then
    NETWORKS=("${NETWORK}")
else
    mapfile -t NETWORKS < <(get_networks)
    # If no networks configured, try to list whatever is on S3
    if [[ ${#NETWORKS[@]} -eq 0 ]]; then
        NETWORKS=("mainnet" "signet" "testnet")
    fi
fi

FOUND=0

for net in "${NETWORKS[@]}"; do
    NET_PATH="${REMOTE_BASE}/${net}"

    # List backup IDs (directories) under this network
    mapfile -t backup_ids < <(rclone lsd "${NET_PATH}/" 2>/dev/null | awk '{print $NF}' | sort -r)

    if [[ ${#backup_ids[@]} -eq 0 ]]; then
        continue
    fi

    log_info "Network: ${net} (${#backup_ids[@]} backup(s))"
    echo ""

    for bid in "${backup_ids[@]}"; do
        [[ -z "${bid}" ]] && continue
        FOUND=$((FOUND + 1))

        MANIFEST_PATH="${NET_PATH}/${bid}/manifest.json"

        # Try to download and parse manifest
        manifest=""
        manifest=$(rclone cat "${MANIFEST_PATH}" 2>/dev/null) || true

        if [[ -n "${manifest}" ]]; then
            # Parse key fields from manifest
            date=$(echo "${manifest}" | grep -o '"date"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
            height=$(echo "${manifest}" | grep -o '"block_height"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
            duration=$(echo "${manifest}" | grep -o '"duration_seconds"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
            btrfs_flag=$(echo "${manifest}" | grep -o '"btrfs"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')

            printf "  %-20s  date=%-25s  height=%-8s  duration=%-6ss  btrfs=%s\n" \
                "${bid}" "${date:-unknown}" "${height:-?}" "${duration:-?}" "${btrfs_flag:-?}"
        else
            # No manifest — just list the backup ID and its files
            printf "  %-20s  (no manifest)\n" "${bid}"
        fi

        # List component files and sizes
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            file_size=$(echo "${line}" | awk '{print $1}')
            file_name=$(echo "${line}" | awk '{print $NF}')
            printf "    %-40s  %s\n" "${file_name}" "${file_size}"
        done < <(rclone ls "${NET_PATH}/${bid}/" 2>/dev/null || true)

        echo ""
    done
done

if [[ ${FOUND} -eq 0 ]]; then
    log_info "No remote backups found."
else
    log_info "Total: ${FOUND} backup(s)"
fi
