#!/usr/bin/env bash
# ==============================================================================
# stop.sh — Stop mempool.space Docker stack services
#
# Usage:
#   ./scripts/node/stop.sh                    # stop all services (docker compose down)
#   ./scripts/node/stop.sh --network mainnet  # stop only mainnet services (keep shared)
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
            echo "  --network NETWORK   Stop only NETWORK's services (keep shared running)"
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
require_command docker "apt install docker.io"

if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found."
    exit 1
fi

if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
fi

# ==============================================================================
# Stop services
# ==============================================================================
cd "${PROJECT_ROOT}"

if [[ -z "${NETWORK}" ]]; then
    log_header "Stopping All Services"
    log_info "Stopping full stack..."
    docker compose down
    log_success "All services stopped."
else
    log_header "Stopping ${NETWORK} Services"

    # Network-specific services only — keep shared running
    NETWORK_SERVICES=("mempool-api-${NETWORK}" "electrs-${NETWORK}" "bitcoind-${NETWORK}")

    log_info "Stopping ${NETWORK} services: ${NETWORK_SERVICES[*]}"
    docker compose stop "${NETWORK_SERVICES[@]}"
    docker compose rm -f "${NETWORK_SERVICES[@]}"

    log_success "${NETWORK} services stopped. Shared services remain running."
fi
