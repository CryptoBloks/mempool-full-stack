#!/usr/bin/env bash
# ==============================================================================
# restore.sh — Restore network data from S3 or local snapshot
#
# Usage:
#   ./scripts/backup/restore.sh mainnet                                    # latest from S3
#   ./scripts/backup/restore.sh mainnet --backup 20260309_120000           # specific backup
#   ./scripts/backup/restore.sh mainnet --source local                     # from local snapshot
#   ./scripts/backup/restore.sh mainnet --component bitcoin,electrs        # specific components
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
BACKUP_ID=""
SOURCE="s3"
COMPONENTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            BACKUP_ID="${2:?--backup requires a value}"
            shift 2
            ;;
        --backup=*)
            BACKUP_ID="${1#*=}"
            shift
            ;;
        --source)
            SOURCE="${2:?--source requires a value}"
            shift 2
            ;;
        --source=*)
            SOURCE="${1#*=}"
            shift
            ;;
        --component|--components)
            COMPONENTS="${2:?--component requires a value}"
            shift 2
            ;;
        --component=*|--components=*)
            COMPONENTS="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 NETWORK [--backup ID] [--source s3|local] [--component COMP1,COMP2]"
            echo ""
            echo "Arguments:"
            echo "  NETWORK                Network to restore (mainnet, signet, testnet)"
            echo ""
            echo "Options:"
            echo "  --backup ID            Backup ID to restore (default: latest)"
            echo "  --source s3|local      Restore from S3 or local snapshot (default: s3)"
            echo "  --component COMP1,...   Restore only specific components (bitcoin,electrs,mempool,mariadb)"
            echo "  -h, --help             Show this help"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "${NETWORK}" ]]; then
                NETWORK="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${NETWORK}" ]]; then
    log_error "NETWORK argument is required."
    echo "Usage: $0 NETWORK [--backup ID] [--source s3|local] [--component COMP1,COMP2]" >&2
    exit 1
fi

# ==============================================================================
# Validate
# ==============================================================================
log_header "Restore: ${NETWORK}"

load_config

if ! validate_network "${NETWORK}"; then
    log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
    exit 1
fi

if [[ "${SOURCE}" != "s3" && "${SOURCE}" != "local" ]]; then
    log_error "Invalid source: ${SOURCE}. Must be 's3' or 'local'."
    exit 1
fi

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"

# Parse component list
ALL_COMPONENTS=("bitcoin" "electrs" "mempool" "mariadb")
if [[ -n "${COMPONENTS}" ]]; then
    IFS=',' read -ra RESTORE_COMPONENTS <<< "${COMPONENTS}"
    for comp in "${RESTORE_COMPONENTS[@]}"; do
        case "${comp}" in
            bitcoin|electrs|mempool|mariadb) ;;
            *)
                log_error "Invalid component: ${comp}. Must be one of: bitcoin, electrs, mempool, mariadb"
                exit 1
                ;;
        esac
    done
else
    RESTORE_COMPONENTS=("${ALL_COMPONENTS[@]}")
fi

# Check BTRFS
USE_BTRFS=false
if stat -f -c %T "${STORAGE_PATH}" 2>/dev/null | grep -q btrfs; then
    USE_BTRFS=true
fi

# ==============================================================================
# Determine backup source and find backup ID
# ==============================================================================
if [[ "${SOURCE}" == "s3" ]]; then
    require_command rclone "curl https://rclone.org/install.sh | sudo bash"
    require_command zstd "apt install zstd"

    S3_REMOTE="$(get_config S3_REMOTE "")"
    S3_BUCKET="$(get_config S3_BUCKET "")"
    S3_PREFIX="$(get_config S3_PREFIX "")"

    if [[ -z "${S3_REMOTE}" || -z "${S3_BUCKET}" ]]; then
        log_error "S3_REMOTE and S3_BUCKET must be set in node.conf"
        exit 1
    fi

    REMOTE_BASE="${S3_REMOTE}:${S3_BUCKET}/${S3_PREFIX}backups/${NETWORK}"

    if [[ -z "${BACKUP_ID}" ]]; then
        # Find latest backup
        log_info "Finding latest backup on S3..."
        BACKUP_ID=$(rclone lsd "${REMOTE_BASE}/" 2>/dev/null | awk '{print $NF}' | sort -r | head -1)
        if [[ -z "${BACKUP_ID}" ]]; then
            log_error "No backups found on S3 for network '${NETWORK}'"
            exit 1
        fi
        log_info "Latest backup: ${BACKUP_ID}"
    fi

    REMOTE_BACKUP="${REMOTE_BASE}/${BACKUP_ID}"

    # Download and verify manifest
    log_info "Downloading manifest..."
    MANIFEST=$(rclone cat "${REMOTE_BACKUP}/manifest.json" 2>/dev/null) || true
    if [[ -z "${MANIFEST}" ]]; then
        log_warn "No manifest.json found for backup ${BACKUP_ID}. Proceeding without verification."
    fi

elif [[ "${SOURCE}" == "local" ]]; then
    SNAPSHOT_DIR="${STORAGE_PATH}/snapshots"

    if [[ ! -d "${SNAPSHOT_DIR}" ]]; then
        log_error "No snapshots directory found at ${SNAPSHOT_DIR}"
        exit 1
    fi

    if [[ -z "${BACKUP_ID}" ]]; then
        # Find latest snapshot timestamp for this network
        BACKUP_ID=$(ls -1d "${SNAPSHOT_DIR}"/*-"${NETWORK}"-* 2>/dev/null \
            | sed 's/.*-\([0-9]\{8\}_[0-9]\{6\}\)$/\1/' \
            | sort -r | head -1)
        if [[ -z "${BACKUP_ID}" ]]; then
            log_error "No local snapshots found for network '${NETWORK}'"
            exit 1
        fi
        log_info "Latest local snapshot: ${BACKUP_ID}"
    fi

    # Try to load local manifest
    MANIFEST=""
    MANIFEST_FILE="${SNAPSHOT_DIR}/manifest-${NETWORK}-${BACKUP_ID}.json"
    if [[ -f "${MANIFEST_FILE}" ]]; then
        MANIFEST="$(cat "${MANIFEST_FILE}")"
    fi
fi

# ==============================================================================
# Show backup details and confirm
# ==============================================================================
log_info "Restore details:"
log_info "  Network:    ${NETWORK}"
log_info "  Backup ID:  ${BACKUP_ID}"
log_info "  Source:      ${SOURCE}"
log_info "  Components:  ${RESTORE_COMPONENTS[*]}"

if [[ -n "${MANIFEST:-}" ]]; then
    date=$(echo "${MANIFEST}" | grep -o '"date"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    height=$(echo "${MANIFEST}" | grep -o '"block_height"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ')
    log_info "  Date:        ${date:-unknown}"
    log_info "  Height:      ${height:-unknown}"
fi

echo ""
log_warn "This will DELETE existing data for the selected components!"

if ! ask_yes_no "Proceed with restore?" "n"; then
    log_info "Restore cancelled."
    exit 0
fi

# ==============================================================================
# Stop all services for the network
# ==============================================================================
log_info "Stopping ${NETWORK} services..."
cd "${PROJECT_ROOT}"

NETWORK_SERVICES=("mempool-api-${NETWORK}" "electrs-${NETWORK}" "bitcoind-${NETWORK}")

# Also stop mariadb if restoring it
if printf '%s\n' "${RESTORE_COMPONENTS[@]}" | grep -q '^mariadb$'; then
    NETWORK_SERVICES+=("mariadb")
fi

for svc in "${NETWORK_SERVICES[@]}"; do
    docker compose stop "${svc}" 2>/dev/null || true
done

# ==============================================================================
# Clear existing data and restore
# ==============================================================================
log_header "Restoring Data"

for comp in "${RESTORE_COMPONENTS[@]}"; do
    if [[ "${comp}" == "mariadb" ]]; then
        TARGET_DIR="${STORAGE_PATH}/mariadb"
    else
        TARGET_DIR="${STORAGE_PATH}/${NETWORK}/${comp}"
    fi

    log_info "Restoring ${comp} -> ${TARGET_DIR}"

    # Clear existing data
    if [[ -d "${TARGET_DIR}" ]]; then
        if [[ "${USE_BTRFS}" == "true" ]]; then
            # Delete BTRFS subvolume and recreate
            btrfs subvolume delete "${TARGET_DIR}" 2>/dev/null || rm -rf "${TARGET_DIR}"
            btrfs subvolume create "${TARGET_DIR}"
        else
            rm -rf "${TARGET_DIR}"
            mkdir -p "${TARGET_DIR}"
        fi
    else
        mkdir -p "${TARGET_DIR}"
    fi

    # Restore data
    if [[ "${SOURCE}" == "s3" ]]; then
        remote_file="${REMOTE_BACKUP}/${comp}.tar.zst"
        log_info "  Downloading from S3: ${remote_file}"

        rclone cat "${remote_file}" \
            | zstd -d \
            | tar -xf - -C "${TARGET_DIR}" --strip-components=1

    elif [[ "${SOURCE}" == "local" ]]; then
        if [[ "${comp}" == "mariadb" ]]; then
            snap_name="${comp}-${BACKUP_ID}"
        else
            snap_name="${comp}-${NETWORK}-${BACKUP_ID}"
        fi
        snap_path="${SNAPSHOT_DIR}/${snap_name}"

        if [[ ! -d "${snap_path}" ]]; then
            log_error "  Snapshot not found: ${snap_path}"
            continue
        fi

        log_info "  Restoring from snapshot: ${snap_path}"
        cp -a "${snap_path}/." "${TARGET_DIR}/"
    fi

    # Fix permissions
    if [[ "${comp}" == "mariadb" ]]; then
        chown -R 999:999 "${TARGET_DIR}" 2>/dev/null || log_warn "  Could not set mariadb ownership (999:999). Run as root."
    else
        chown -R 1000:1000 "${TARGET_DIR}" 2>/dev/null || log_warn "  Could not set ${comp} ownership (1000:1000). Run as root."
    fi

    log_success "Restored: ${comp}"
done

# ==============================================================================
# Start services
# ==============================================================================
log_info "Starting services..."
cd "${PROJECT_ROOT}"

# Start in dependency order
if printf '%s\n' "${RESTORE_COMPONENTS[@]}" | grep -q '^mariadb$'; then
    docker compose start mariadb 2>/dev/null || true
    sleep 3  # Give MariaDB time to initialize
fi

for svc in "bitcoind-${NETWORK}" "electrs-${NETWORK}" "mempool-api-${NETWORK}"; do
    docker compose start "${svc}" 2>/dev/null || true
done

log_header "Restore Complete"
log_success "Network:    ${NETWORK}"
log_success "Backup ID:  ${BACKUP_ID}"
log_success "Source:      ${SOURCE}"
log_success "Components:  ${RESTORE_COMPONENTS[*]}"
