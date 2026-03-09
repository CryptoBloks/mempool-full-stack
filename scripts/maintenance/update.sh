#!/usr/bin/env bash
# ==============================================================================
# update.sh — Check for and apply updates to mempool.space stack
#
# Usage:
#   ./scripts/maintenance/update.sh              # check and apply updates
#   ./scripts/maintenance/update.sh --check-only # just report available updates
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
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--check-only]"
            echo ""
            echo "Options:"
            echo "  --check-only   Just report available updates, do not apply"
            echo "  -h, --help     Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# Setup
# ==============================================================================
require_command docker "apt install docker.io"
require_command curl

load_config

log_header "Update Check"

UPDATES_AVAILABLE=0

# ==============================================================================
# Check Bitcoin Core version
# ==============================================================================
log_info "Checking Bitcoin Core version..."

CURRENT_BITCOIN="$(get_config BITCOIN_VERSION "unknown")"

# Query GitHub API for latest release
LATEST_BITCOIN=""
if gh_response=$(curl -sf "https://api.github.com/repos/bitcoin/bitcoin/releases/latest" 2>/dev/null); then
    LATEST_BITCOIN=$(echo "${gh_response}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
fi

if [[ -n "${LATEST_BITCOIN}" ]]; then
    if [[ "${CURRENT_BITCOIN}" == "${LATEST_BITCOIN}" ]]; then
        log_success "Bitcoin Core: ${CURRENT_BITCOIN} (up to date)"
    else
        log_warn "Bitcoin Core: ${CURRENT_BITCOIN} -> ${LATEST_BITCOIN} available"
        UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
    fi
else
    log_warn "Bitcoin Core: ${CURRENT_BITCOIN} (unable to check latest)"
fi

# ==============================================================================
# Check Mempool version
# ==============================================================================
log_info "Checking Mempool version..."

CURRENT_MEMPOOL="$(get_config MEMPOOL_VERSION "unknown")"

LATEST_MEMPOOL=""
if gh_response=$(curl -sf "https://api.github.com/repos/mempool/mempool/releases/latest" 2>/dev/null); then
    LATEST_MEMPOOL=$(echo "${gh_response}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
fi

if [[ -n "${LATEST_MEMPOOL}" ]]; then
    if [[ "${CURRENT_MEMPOOL}" == "${LATEST_MEMPOOL}" ]]; then
        log_success "Mempool: ${CURRENT_MEMPOOL} (up to date)"
    else
        log_warn "Mempool: ${CURRENT_MEMPOOL} -> ${LATEST_MEMPOOL} available"
        UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
    fi
else
    log_warn "Mempool: ${CURRENT_MEMPOOL} (unable to check latest)"
fi

# ==============================================================================
# Check MariaDB version
# ==============================================================================
log_info "Checking MariaDB version..."

CURRENT_MARIADB="$(get_config MARIADB_VERSION "unknown")"
log_info "MariaDB: ${CURRENT_MARIADB} (manual upgrade recommended for databases)"

# ==============================================================================
# Summary for --check-only
# ==============================================================================
if [[ "${CHECK_ONLY}" == "true" ]]; then
    echo ""
    if [[ ${UPDATES_AVAILABLE} -eq 0 ]]; then
        log_success "All components are up to date."
    else
        log_info "${UPDATES_AVAILABLE} update(s) available."
    fi
    exit 0
fi

# ==============================================================================
# Apply updates
# ==============================================================================
if [[ ${UPDATES_AVAILABLE} -eq 0 ]]; then
    log_success "All components are up to date. Nothing to do."
    exit 0
fi

echo ""
log_warn "Updates will pull new Docker images and recreate containers."
log_warn "Services will experience brief downtime during recreation."

if ! ask_yes_no "Apply updates?" "n"; then
    log_info "Update cancelled."
    exit 0
fi

cd "${PROJECT_ROOT}"

# Update Bitcoin Core version in node.conf
if [[ -n "${LATEST_BITCOIN}" && "${CURRENT_BITCOIN}" != "${LATEST_BITCOIN}" ]]; then
    log_info "Updating Bitcoin Core: ${CURRENT_BITCOIN} -> ${LATEST_BITCOIN}"
    set_config "BITCOIN_VERSION" "${LATEST_BITCOIN}"
fi

# Update Mempool version in node.conf
if [[ -n "${LATEST_MEMPOOL}" && "${CURRENT_MEMPOOL}" != "${LATEST_MEMPOOL}" ]]; then
    log_info "Updating Mempool: ${CURRENT_MEMPOOL} -> ${LATEST_MEMPOOL}"
    set_config "MEMPOOL_VERSION" "${LATEST_MEMPOOL}"
fi

# Regenerate configuration files
log_info "Regenerating configuration..."
if [[ -x "${PROJECT_ROOT}/scripts/setup/generate-config.sh" ]]; then
    "${PROJECT_ROOT}/scripts/setup/generate-config.sh"
else
    log_warn "generate-config.sh not found or not executable. Skipping config regeneration."
fi

# Pull new images
log_info "Pulling new Docker images..."
docker compose pull

# Recreate containers with new images
log_info "Recreating containers..."
docker compose up -d

log_header "Update Complete"
log_success "Stack has been updated and restarted."
if [[ -n "${LATEST_BITCOIN}" && "${CURRENT_BITCOIN}" != "${LATEST_BITCOIN}" ]]; then
    log_success "  Bitcoin Core: ${CURRENT_BITCOIN} -> ${LATEST_BITCOIN}"
fi
if [[ -n "${LATEST_MEMPOOL}" && "${CURRENT_MEMPOOL}" != "${LATEST_MEMPOOL}" ]]; then
    log_success "  Mempool: ${CURRENT_MEMPOOL} -> ${LATEST_MEMPOOL}"
fi
