#!/usr/bin/env bash
# ==============================================================================
# restart.sh — Restart mempool.space Docker stack services
#
# Usage:
#   ./scripts/node/restart.sh                    # restart all services
#   ./scripts/node/restart.sh --network mainnet  # restart only mainnet services
# ==============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"

# ==============================================================================
# Parse arguments (pass through to stop/start)
# ==============================================================================
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $0 [--network NETWORK]"
            echo ""
            echo "Options:"
            echo "  --network NETWORK   Restart only NETWORK's services"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# ==============================================================================
# Restart = stop + start
# ==============================================================================
log_header "Restarting Services"

log_info "Stopping services..."
"${_SCRIPT_DIR}/stop.sh" "${ARGS[@]}" || log_warn "Stop encountered errors, proceeding with start..."

log_info "Starting services..."
"${_SCRIPT_DIR}/start.sh" "${ARGS[@]}"

log_success "Restart complete."
