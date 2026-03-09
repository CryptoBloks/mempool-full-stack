#!/usr/bin/env bash
# ==============================================================================
# full-backup.sh — Full backup of a network's data to S3
#
# Usage:
#   ./scripts/backup/full-backup.sh mainnet
#   ./scripts/backup/full-backup.sh mainnet --no-upload   # local snapshot only
#
# Flow:
#   1. Pre-checks (BTRFS, rclone, zstd, S3 config)
#   2. Generate backup ID
#   3. Stop network services
#   4. If BTRFS: snapshot, restart immediately
#   5. If not BTRFS: services stay stopped during upload
#   6. Stream upload each component
#   7. Generate and upload manifest.json
#   8. If non-BTRFS: restart services
#   9. Cleanup snapshots
#  10. Run prune if BACKUP_RETENTION is set
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
NO_UPLOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-upload)
            NO_UPLOAD=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 NETWORK [--no-upload]"
            echo ""
            echo "Arguments:"
            echo "  NETWORK        Network to back up (mainnet, signet, testnet)"
            echo ""
            echo "Options:"
            echo "  --no-upload    Create local snapshot only, do not upload to S3"
            echo "  -h, --help     Show this help"
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
    echo "Usage: $0 NETWORK [--no-upload]" >&2
    exit 1
fi

# ==============================================================================
# Pre-checks
# ==============================================================================
log_header "Full Backup: ${NETWORK}"

load_config

if ! validate_network "${NETWORK}"; then
    log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
    exit 1
fi

STORAGE_PATH="$(get_config STORAGE_PATH "/data/mempool")"
BACKUP_ID="$(date '+%Y%m%d_%H%M%S')"
START_TIME=$(date +%s)

# Check BTRFS
USE_BTRFS=false
if stat -f -c %T "${STORAGE_PATH}" 2>/dev/null | grep -q btrfs; then
    USE_BTRFS=true
    log_info "BTRFS filesystem detected. Will use snapshots for consistent backup."
    require_command btrfs "apt install btrfs-progs"
else
    log_warn "Not a BTRFS filesystem. Services will stay stopped during backup."
fi

if [[ "${NO_UPLOAD}" == "false" ]]; then
    require_command rclone "curl https://rclone.org/install.sh | sudo bash"
    require_command zstd "apt install zstd"

    # Verify S3 config
    S3_ENABLED="$(get_config S3_ENABLED "false")"
    if [[ "${S3_ENABLED}" != "true" ]]; then
        log_error "S3 is not enabled in node.conf. Set S3_ENABLED=true"
        exit 1
    fi

    S3_REMOTE="$(get_config S3_REMOTE "")"
    S3_BUCKET="$(get_config S3_BUCKET "")"
    S3_PREFIX="$(get_config S3_PREFIX "")"

    if [[ -z "${S3_REMOTE}" ]]; then
        log_error "S3_REMOTE is not set in node.conf"
        exit 1
    fi
    if [[ -z "${S3_BUCKET}" ]]; then
        log_error "S3_BUCKET is not set in node.conf"
        exit 1
    fi

    # Verify rclone remote is configured
    if ! rclone listremotes 2>/dev/null | grep -q "^${S3_REMOTE}:$"; then
        log_error "rclone remote '${S3_REMOTE}' not found. Configure with: rclone config"
        exit 1
    fi

    REMOTE_BASE="${S3_REMOTE}:${S3_BUCKET}/${S3_PREFIX}backups/${NETWORK}/${BACKUP_ID}"
    log_info "Remote path: ${REMOTE_BASE}"
fi

log_info "Backup ID: ${BACKUP_ID}"

# ==============================================================================
# Define components and their paths
# ==============================================================================
declare -A COMP_PATHS
COMP_PATHS["bitcoin"]="${STORAGE_PATH}/${NETWORK}/bitcoin"
COMP_PATHS["electrs"]="${STORAGE_PATH}/${NETWORK}/electrs"
COMP_PATHS["mempool"]="${STORAGE_PATH}/${NETWORK}/mempool"
COMP_PATHS["mariadb"]="${STORAGE_PATH}/mariadb"

# Filter to only existing directories
declare -A BACKUP_SOURCES
for comp in "${!COMP_PATHS[@]}"; do
    if [[ -d "${COMP_PATHS[${comp}]}" ]]; then
        BACKUP_SOURCES["${comp}"]="${COMP_PATHS[${comp}]}"
    else
        log_warn "Component directory not found, skipping: ${COMP_PATHS[${comp}]}"
    fi
done

if [[ ${#BACKUP_SOURCES[@]} -eq 0 ]]; then
    log_error "No data directories found to back up."
    exit 1
fi

# ==============================================================================
# Stop services
# ==============================================================================
log_info "Stopping ${NETWORK} services..."
cd "${PROJECT_ROOT}"

NETWORK_SERVICES=("mempool-api-${NETWORK}" "electrs-${NETWORK}" "bitcoind-${NETWORK}")
for svc in "${NETWORK_SERVICES[@]}"; do
    docker compose stop "${svc}" 2>/dev/null || true
done

# ==============================================================================
# Create BTRFS snapshots (if applicable)
# ==============================================================================
SNAPSHOT_DIR="${STORAGE_PATH}/snapshots"
declare -A SNAP_PATHS

if [[ "${USE_BTRFS}" == "true" ]]; then
    log_info "Creating BTRFS snapshots..."
    mkdir -p "${SNAPSHOT_DIR}"

    for comp in "${!BACKUP_SOURCES[@]}"; do
        src="${BACKUP_SOURCES[${comp}]}"
        snap_name="${comp}-${NETWORK}-${BACKUP_ID}"
        snap_path="${SNAPSHOT_DIR}/${snap_name}"

        if btrfs subvolume snapshot -r "${src}" "${snap_path}"; then
            SNAP_PATHS["${comp}"]="${snap_path}"
            log_success "Snapshot: ${snap_name}"
        else
            log_error "Failed to snapshot ${comp}. Aborting."
            # Restart services before exiting
            for svc in "bitcoind-${NETWORK}" "electrs-${NETWORK}" "mempool-api-${NETWORK}"; do
                docker compose start "${svc}" 2>/dev/null || true
            done
            exit 1
        fi
    done

    # Restart services immediately — we have the snapshots
    log_info "Restarting ${NETWORK} services (snapshots are ready)..."
    for svc in "bitcoind-${NETWORK}" "electrs-${NETWORK}" "mempool-api-${NETWORK}"; do
        docker compose start "${svc}" 2>/dev/null || true
    done
    log_success "Services restarted."
fi

# ==============================================================================
# Upload components
# ==============================================================================
declare -A COMP_SIZES

if [[ "${NO_UPLOAD}" == "false" ]]; then
    log_header "Uploading to S3"

    for comp in "${!BACKUP_SOURCES[@]}"; do
        # Use snapshot path if available, otherwise original path
        if [[ -n "${SNAP_PATHS[${comp}]:-}" ]]; then
            source_path="${SNAP_PATHS[${comp}]}"
        else
            source_path="${BACKUP_SOURCES[${comp}]}"
        fi

        remote_file="${REMOTE_BASE}/${comp}.tar.zst"
        log_info "Uploading ${comp} from ${source_path}..."

        # Stream: tar | zstd | rclone rcat
        tar -cf - -C "$(dirname "${source_path}")" "$(basename "${source_path}")" \
            | zstd -T0 -3 \
            | rclone rcat "${remote_file}"

        log_success "Uploaded: ${comp}.tar.zst"

        # Record size of source
        COMP_SIZES["${comp}"]="$(du -sb "${source_path}" 2>/dev/null | awk '{print $1}')" || COMP_SIZES["${comp}"]=0
    done
else
    log_info "Skipping upload (--no-upload specified)."
    for comp in "${!BACKUP_SOURCES[@]}"; do
        source_path="${SNAP_PATHS[${comp}]:-${BACKUP_SOURCES[${comp}]}}"
        COMP_SIZES["${comp}"]="$(du -sb "${source_path}" 2>/dev/null | awk '{print $1}')" || COMP_SIZES["${comp}"]=0
    done
fi

# ==============================================================================
# Generate and upload manifest.json
# ==============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Get Bitcoin block height and version
BLOCK_HEIGHT=0
BITCOIN_VERSION="$(get_config BITCOIN_VERSION "unknown")"
TXINDEX="$(get_config BITCOIN_TXINDEX "true")"
MEMPOOL_VERSION="$(get_config MEMPOOL_VERSION "unknown")"
ELECTRS_VERSION="$(get_config ELECTRS_VERSION "latest")"
MARIADB_VERSION="$(get_config MARIADB_VERSION "10.11")"

rpc_user="$(get_config BITCOIN_RPC_USER "mempool")"
rpc_pass="$(get_config BITCOIN_RPC_PASS "")"

if [[ -n "${rpc_pass}" ]]; then
    if info=$(docker compose exec -T "bitcoind-${NETWORK}" bitcoin-cli \
        -rpcuser="${rpc_user}" -rpcpassword="${rpc_pass}" \
        getblockchaininfo 2>/dev/null); then
        BLOCK_HEIGHT=$(echo "${info}" | grep -o '"blocks"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | awk -F: '{print $2}' | tr -d ' ') || true
    fi
fi

# Build manifest
MANIFEST=$(cat <<MANIFEST_EOF
{
  "backup_id": "${BACKUP_ID}",
  "network": "${NETWORK}",
  "date": "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')",
  "components": {
    "bitcoin": {
      "version": "${BITCOIN_VERSION}",
      "block_height": ${BLOCK_HEIGHT:-0},
      "txindex": ${TXINDEX},
      "size_bytes": ${COMP_SIZES["bitcoin"]:-0}
    },
    "electrs": {
      "version": "${ELECTRS_VERSION}",
      "size_bytes": ${COMP_SIZES["electrs"]:-0}
    },
    "mariadb": {
      "version": "${MARIADB_VERSION}",
      "databases": ["mempool"],
      "size_bytes": ${COMP_SIZES["mariadb"]:-0}
    },
    "mempool": {
      "version": "${MEMPOOL_VERSION}",
      "size_bytes": ${COMP_SIZES["mempool"]:-0}
    }
  },
  "btrfs": ${USE_BTRFS},
  "zstd_level": 3,
  "duration_seconds": ${DURATION}
}
MANIFEST_EOF
)

# Save manifest locally
MANIFEST_LOCAL="${SNAPSHOT_DIR}/manifest-${NETWORK}-${BACKUP_ID}.json"
mkdir -p "$(dirname "${MANIFEST_LOCAL}")"
echo "${MANIFEST}" > "${MANIFEST_LOCAL}"
log_info "Manifest saved: ${MANIFEST_LOCAL}"

if [[ "${NO_UPLOAD}" == "false" ]]; then
    echo "${MANIFEST}" | rclone rcat "${REMOTE_BASE}/manifest.json"
    log_success "Manifest uploaded."
fi

# ==============================================================================
# Non-BTRFS: restart services now
# ==============================================================================
if [[ "${USE_BTRFS}" == "false" ]]; then
    log_info "Restarting ${NETWORK} services..."
    cd "${PROJECT_ROOT}"
    for svc in "bitcoind-${NETWORK}" "electrs-${NETWORK}" "mempool-api-${NETWORK}"; do
        docker compose start "${svc}" 2>/dev/null || true
    done
    log_success "Services restarted."
fi

# ==============================================================================
# Cleanup BTRFS snapshots
# ==============================================================================
if [[ "${USE_BTRFS}" == "true" ]]; then
    log_info "Cleaning up backup snapshots..."
    for comp in "${!SNAP_PATHS[@]}"; do
        snap_path="${SNAP_PATHS[${comp}]}"
        if [[ -d "${snap_path}" ]]; then
            btrfs subvolume delete "${snap_path}" 2>/dev/null || rm -rf "${snap_path}" 2>/dev/null || true
        fi
    done
    log_success "Snapshots cleaned up."
fi

# ==============================================================================
# Run prune if BACKUP_RETENTION is set
# ==============================================================================
RETENTION="$(get_config BACKUP_RETENTION "")"
if [[ -n "${RETENTION}" && "${NO_UPLOAD}" == "false" ]]; then
    log_info "Running S3 prune with retention=${RETENTION}..."
    "${_SCRIPT_DIR}/s3-prune.sh" --keep "${RETENTION}" --network "${NETWORK}" || true
fi

# ==============================================================================
# Summary
# ==============================================================================
log_header "Backup Complete"
log_success "Backup ID:  ${BACKUP_ID}"
log_success "Network:    ${NETWORK}"
log_success "Duration:   ${DURATION}s"
log_success "Components: ${!BACKUP_SOURCES[*]}"
if [[ "${NO_UPLOAD}" == "false" ]]; then
    log_success "Remote:     ${REMOTE_BASE}"
fi
