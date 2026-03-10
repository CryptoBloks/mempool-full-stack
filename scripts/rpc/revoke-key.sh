#!/usr/bin/env bash
# ==============================================================================
# revoke-key.sh — Disable or remove an RPC API key
#
# Usage:
#   ./scripts/rpc/revoke-key.sh KEY [--delete]
#
# Without --delete: sets the key's enabled field to false (soft revoke).
# With --delete: removes the key entirely from api-keys.json.
#
# Reloads OpenResty after modification.
# ==============================================================================
set -euo pipefail

# Source shared libraries
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_SCRIPT_DIR}/../lib/config-utils.sh"

# Require jq
require_command jq "sudo apt install jq"

# Defaults
DELETE_KEY=false
TARGET_KEY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete)
            DELETE_KEY=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: revoke-key.sh KEY [OPTIONS]

Disable or remove an RPC API key.

Arguments:
  KEY           The full API key string to revoke

Options:
  --delete      Remove the key entirely (default: disable only)
  -h, --help    Show this help message

Examples:
  revoke-key.sh mk_live_abc123def456      # Disable the key
  revoke-key.sh mk_live_abc123def456 --delete  # Remove the key
USAGE
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            log_error "Use --help for usage information."
            exit 1
            ;;
        *)
            if [[ -z "${TARGET_KEY}" ]]; then
                TARGET_KEY="$1"
            else
                log_error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate key was provided
if [[ -z "${TARGET_KEY}" ]]; then
    log_error "API key argument is required."
    log_error "Usage: revoke-key.sh KEY [--delete]"
    exit 1
fi

# Locate api-keys.json
API_KEYS_FILE="${PROJECT_ROOT}/config/openresty/api-keys.json"

if [[ ! -f "${API_KEYS_FILE}" ]]; then
    log_error "api-keys.json not found at ${API_KEYS_FILE}"
    exit 1
fi

# Validate JSON
if ! jq empty "${API_KEYS_FILE}" 2>/dev/null; then
    log_error "api-keys.json is not valid JSON: ${API_KEYS_FILE}"
    exit 1
fi

# Check that the key exists
if ! jq -e --arg key "${TARGET_KEY}" 'has($key)' "${API_KEYS_FILE}" >/dev/null 2>&1; then
    log_error "API key not found in api-keys.json: ${TARGET_KEY}"
    exit 1
fi

# Get key name for display
KEY_NAME=$(jq -r --arg key "${TARGET_KEY}" '.[$key].name // "unknown"' "${API_KEYS_FILE}")

if [[ "${DELETE_KEY}" == "true" ]]; then
    # Remove the key entirely
    UPDATED=$(jq --arg key "${TARGET_KEY}" 'del(.[$key])' "${API_KEYS_FILE}")
    echo "${UPDATED}" > "${API_KEYS_FILE}"
    log_success "Deleted API key '${KEY_NAME}' from ${API_KEYS_FILE}"
else
    # Disable the key (set enabled=false)
    UPDATED=$(jq --arg key "${TARGET_KEY}" '.[$key].enabled = false' "${API_KEYS_FILE}")
    echo "${UPDATED}" > "${API_KEYS_FILE}"
    log_success "Disabled API key '${KEY_NAME}' in ${API_KEYS_FILE}"
fi

# Reload OpenResty if running
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^openresty$'; then
    log_info "Reloading OpenResty..."
    if docker exec openresty nginx -s reload 2>/dev/null; then
        log_success "OpenResty reloaded successfully."
    else
        log_warn "Failed to reload OpenResty. You may need to restart it manually."
    fi
else
    log_info "OpenResty container not running; reload skipped."
fi
