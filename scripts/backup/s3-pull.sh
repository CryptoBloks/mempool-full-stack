#!/usr/bin/env bash
# ==============================================================================
# s3-pull.sh — Streaming download from S3
#
# Usage:
#   ./scripts/backup/s3-pull.sh REMOTE_PATH DEST_DIR
#
# Streams: rclone cat REMOTE_PATH | zstd -d | tar -xf - -C DEST_DIR
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
    echo "Usage: $0 REMOTE_PATH DEST_DIR"
    echo ""
    echo "Arguments:"
    echo "  REMOTE_PATH   rclone remote path (e.g., myremote:bucket/path/file.tar.zst)"
    echo "  DEST_DIR      Local directory to extract into"
    echo ""
    echo "Streams rclone cat | zstd -d | tar -xf for efficient download."
    [[ "$1" == "-h" || "$1" == "--help" ]] && exit 0
    exit 1
fi

REMOTE_PATH="$1"
DEST_DIR="$2"

# ==============================================================================
# Validate
# ==============================================================================
require_command rclone "curl https://rclone.org/install.sh | sudo bash"
require_command zstd "apt install zstd"
require_command tar

# ==============================================================================
# Download
# ==============================================================================
log_info "Downloading ${REMOTE_PATH} -> ${DEST_DIR}"

mkdir -p "${DEST_DIR}"

START_TIME=$(date +%s)

rclone cat "${REMOTE_PATH}" \
    | zstd -d \
    | tar -xf - -C "${DEST_DIR}" --strip-components=1

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_success "Download complete in ${DURATION}s: ${DEST_DIR}"
