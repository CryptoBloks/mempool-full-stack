#!/usr/bin/env bash
# ==============================================================================
# start.sh — Start mempool.space Docker stack services
#
# Usage:
#   ./scripts/node/start.sh                  # start all services
#   ./scripts/node/start.sh --network mainnet  # start mainnet + shared services
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
            echo "  --network NETWORK   Start only NETWORK's services + shared services"
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

# Verify config exists
if [[ ! -f "${PROJECT_ROOT}/node.conf" ]]; then
    log_error "node.conf not found. Run the wizard first: ./scripts/setup/wizard.sh"
    exit 1
fi

# Verify docker-compose.yml exists
if [[ ! -f "${PROJECT_ROOT}/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found. Run: ./scripts/setup/generate-config.sh"
    exit 1
fi

load_config

# Validate network if specified
if [[ -n "${NETWORK}" ]]; then
    if ! validate_network "${NETWORK}"; then
        log_error "Invalid network: ${NETWORK}. Must be one of: ${SUPPORTED_NETWORKS}"
        exit 1
    fi
    if ! is_network_enabled "${NETWORK}"; then
        log_error "Network '${NETWORK}' is not enabled in node.conf"
        exit 1
    fi
fi

# ==============================================================================
# Start services
# ==============================================================================
cd "${PROJECT_ROOT}"

if [[ -z "${NETWORK}" ]]; then
    log_header "Starting All Services"
    log_info "Starting full stack..."
    docker compose up -d

    # Ensure databases exist for all configured networks (idempotent).
    # The entrypoint init only runs on first MariaDB start, so if networks
    # were added after initial setup, this ensures the new databases are created.
    init_sql="${PROJECT_ROOT}/config/mariadb/init/01-init.sql"
    if [[ -f "${init_sql}" ]]; then
        log_info "Waiting for MariaDB to be ready..."
        for i in {1..30}; do
            if docker compose exec -T mariadb mariadb -u root -p"$(get_config MARIADB_ROOT_PASS)" -e "SELECT 1" &>/dev/null; then
                break
            fi
            sleep 1
        done
        log_info "Ensuring MariaDB databases exist..."
        if ! docker compose exec -T mariadb mariadb -u root -p"$(get_config MARIADB_ROOT_PASS)" < "${init_sql}"; then
            log_warn "MariaDB init SQL failed. Databases may need manual creation."
        fi
    fi

    log_success "All services started."
else
    log_header "Starting ${NETWORK} Services"

    # Shared services that should always be running
    SHARED_SERVICES=("mariadb" "mempool-web" "openresty")

    # Check if cloudflared is enabled
    if [[ "$(get_config CLOUDFLARE_TUNNEL_ENABLED "false")" == "true" ]]; then
        SHARED_SERVICES+=("cloudflared")
    fi

    # Network-specific services
    NETWORK_SERVICES=("bitcoind-${NETWORK}" "electrs-${NETWORK}" "mempool-api-${NETWORK}")

    # Start shared services first
    log_info "Starting shared services: ${SHARED_SERVICES[*]}"
    docker compose up -d "${SHARED_SERVICES[@]}"

    # Ensure databases exist (in case this network was added after initial setup)
    init_sql="${PROJECT_ROOT}/config/mariadb/init/01-init.sql"
    if [[ -f "${init_sql}" ]]; then
        log_info "Waiting for MariaDB to be ready..."
        for i in {1..30}; do
            if docker compose exec -T mariadb mariadb -u root -p"$(get_config MARIADB_ROOT_PASS)" -e "SELECT 1" &>/dev/null; then
                break
            fi
            sleep 1
        done
        log_info "Ensuring MariaDB databases exist..."
        if ! docker compose exec -T mariadb mariadb -u root -p"$(get_config MARIADB_ROOT_PASS)" < "${init_sql}"; then
            log_warn "MariaDB init SQL failed. Databases may need manual creation."
        fi
    fi

    # Start network services
    log_info "Starting ${NETWORK} services: ${NETWORK_SERVICES[*]}"
    docker compose up -d "${NETWORK_SERVICES[@]}"

    log_success "${NETWORK} services started."
fi
