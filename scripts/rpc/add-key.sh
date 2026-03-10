#!/usr/bin/env bash
# ==============================================================================
# add-key.sh — Generate and add a new RPC API key
#
# Usage:
#   ./scripts/rpc/add-key.sh [--name NAME] [--rate-limit N] [--profile PROFILE]
#
# Options:
#   --name NAME         Friendly name for the key (default: "unnamed")
#   --rate-limit N      Requests per minute (default: 60)
#   --profile PROFILE   Method profile: read-only, standard, full (informational)
#
# Generates a new key (mk_live_ + 32 hex chars), adds it to api-keys.json,
# and reloads OpenResty to apply the change.
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
KEY_NAME="unnamed"
RATE_LIMIT=60
PROFILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            KEY_NAME="${2:?--name requires a value}"
            shift 2
            ;;
        --rate-limit)
            RATE_LIMIT="${2:?--rate-limit requires a value}"
            shift 2
            ;;
        --profile)
            PROFILE="${2:?--profile requires a value}"
            shift 2
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: add-key.sh [OPTIONS]

Generate and add a new RPC API key.

Options:
  --name NAME         Friendly name for the key (default: "unnamed")
  --rate-limit N      Requests per minute (default: 60)
  --profile PROFILE   Method profile note (informational, stored in JSON)
  -h, --help          Show this help message
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_error "Use --help for usage information."
            exit 1
            ;;
    esac
done

# Validate rate limit is a positive integer
if [[ ! "${RATE_LIMIT}" =~ ^[0-9]+$ ]] || [[ "${RATE_LIMIT}" -lt 1 ]]; then
    log_error "Rate limit must be a positive integer, got: ${RATE_LIMIT}"
    exit 1
fi

# Locate api-keys.json
API_KEYS_FILE="${PROJECT_ROOT}/config/openresty/api-keys.json"

if [[ ! -f "${API_KEYS_FILE}" ]]; then
    log_warn "api-keys.json not found at ${API_KEYS_FILE}, creating new file."
    mkdir -p "$(dirname "${API_KEYS_FILE}")"
    echo '{}' > "${API_KEYS_FILE}"
fi

# Validate existing JSON
if ! jq empty "${API_KEYS_FILE}" 2>/dev/null; then
    log_error "Existing api-keys.json is not valid JSON: ${API_KEYS_FILE}"
    exit 1
fi

# Generate new key: mk_live_ + 32 hex characters
NEW_KEY="mk_live_$(generate_password 32)"

# Build the key entry
ENTRY=$(jq -n \
    --arg name "${KEY_NAME}" \
    --argjson rate_limit "${RATE_LIMIT}" \
    --arg profile "${PROFILE}" \
    '{
        name: $name,
        enabled: true,
        rate_limit: $rate_limit
    } + (if $profile != "" then {profile: $profile} else {} end)')

# Add to api-keys.json
UPDATED=$(jq --arg key "${NEW_KEY}" --argjson entry "${ENTRY}" \
    '. + {($key): $entry}' "${API_KEYS_FILE}")

echo "${UPDATED}" > "${API_KEYS_FILE}"

log_success "Added new API key to ${API_KEYS_FILE}"

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

# Print the new key
echo ""
log_info "New API key details:"
echo "  Key:        ${NEW_KEY}"
echo "  Name:       ${KEY_NAME}"
echo "  Rate Limit: ${RATE_LIMIT} req/min"
if [[ -n "${PROFILE}" ]]; then
    echo "  Profile:    ${PROFILE}"
fi
echo ""
log_info "Use this key in the X-API-Key header or in the URL path: /v1/${NEW_KEY}"
