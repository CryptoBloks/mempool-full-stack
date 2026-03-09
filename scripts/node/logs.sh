#!/usr/bin/env bash
# ==============================================================================
# logs.sh — View logs for mempool.space Docker stack services
#
# Usage:
#   ./scripts/node/logs.sh                          # all container logs
#   ./scripts/node/logs.sh bitcoind-mainnet          # specific service logs
#   ./scripts/node/logs.sh bitcoind-mainnet --follow  # tail -f equivalent
#   ./scripts/node/logs.sh --lines 50                # last 50 lines
# ==============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"

# ==============================================================================
# Parse arguments
# ==============================================================================
SERVICE=""
FOLLOW=false
LINES=100

while [[ $# -gt 0 ]]; do
    case "$1" in
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        --lines|-n)
            LINES="${2:?--lines requires a value}"
            shift 2
            ;;
        --lines=*)
            LINES="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [SERVICE] [--follow] [--lines N]"
            echo ""
            echo "Arguments:"
            echo "  SERVICE             Service name (e.g., bitcoind-mainnet, mariadb)"
            echo ""
            echo "Options:"
            echo "  --follow, -f        Follow log output (tail -f)"
            echo "  --lines N, -n N     Number of lines to show (default: 100)"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "${SERVICE}" ]]; then
                SERVICE="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
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

# ==============================================================================
# Show logs
# ==============================================================================
cd "${PROJECT_ROOT}"

DOCKER_ARGS=("--tail" "${LINES}")

if [[ "${FOLLOW}" == "true" ]]; then
    DOCKER_ARGS+=("--follow")
fi

if [[ -n "${SERVICE}" ]]; then
    docker compose logs "${DOCKER_ARGS[@]}" "${SERVICE}"
else
    docker compose logs "${DOCKER_ARGS[@]}"
fi
