#!/usr/bin/env bash
# ==============================================================================
# s3-push.sh — Streaming upload of a directory to S3
#
# Usage:
#   ./scripts/backup/s3-push.sh SOURCE_DIR REMOTE_PATH
#
# Streams: tar -cf - SOURCE | zstd -T0 -3 | rclone rcat REMOTE_PATH
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
if [[ $# -lt 2 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $0 SOURCE_DIR REMOTE_PATH"
    echo ""
    echo "Arguments:"
    echo "  SOURCE_DIR    Local directory to upload"
    echo "  REMOTE_PATH   rclone remote path (e.g., myremote:bucket/path/file.tar.zst)"
    echo ""
    echo "Streams tar | zstd | rclone rcat for efficient upload."
    [[ "$1" == "-h" || "$1" == "--help" ]] && exit 0
    exit 1
fi

SOURCE_DIR="$1"
REMOTE_PATH="$2"

# ==============================================================================
# Validate
# ==============================================================================
require_command rclone "curl https://rclone.org/install.sh | sudo bash"
require_command zstd "apt install zstd"
require_command tar

if [[ ! -d "${SOURCE_DIR}" ]]; then
    log_error "Source directory does not exist: ${SOURCE_DIR}"
    exit 1
fi

# ==============================================================================
# Upload
# ==============================================================================
log_info "Uploading ${SOURCE_DIR} -> ${REMOTE_PATH}"

SOURCE_PARENT="$(dirname "${SOURCE_DIR}")"
SOURCE_BASE="$(basename "${SOURCE_DIR}")"

# Get source size for progress info
SOURCE_SIZE="$(du -sh "${SOURCE_DIR}" 2>/dev/null | awk '{print $1}')" || SOURCE_SIZE="unknown"
log_info "Source size: ${SOURCE_SIZE}"

START_TIME=$(date +%s)

tar -cf - -C "${SOURCE_PARENT}" "${SOURCE_BASE}" \
    | zstd -T0 -3 \
    | rclone rcat "${REMOTE_PATH}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_success "Upload complete in ${DURATION}s: ${REMOTE_PATH}"
