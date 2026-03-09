#!/usr/bin/env bash
# ==============================================================================
# list-keys.sh — List all RPC API keys
#
# Usage:
#   ./scripts/rpc/list-keys.sh [--json]
#
# Options:
#   --json    Output in JSON format instead of table
#
# Reads api-keys.json and displays keys in a human-readable table or JSON.
# Keys are masked by default (mk_live_...last4).
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
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: list-keys.sh [OPTIONS]

List all RPC API keys.

Options:
  --json    Output in JSON format
  -h, --help Show this help message
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

# Locate api-keys.json
API_KEYS_FILE="${PROJECT_ROOT}/config/openresty/api-keys.json"

if [[ ! -f "${API_KEYS_FILE}" ]]; then
    log_error "api-keys.json not found at ${API_KEYS_FILE}"
    log_error "Run generate-config.sh first or add a key with add-key.sh."
    exit 1
fi

# Validate JSON
if ! jq empty "${API_KEYS_FILE}" 2>/dev/null; then
    log_error "api-keys.json is not valid JSON: ${API_KEYS_FILE}"
    exit 1
fi

# Check if empty
KEY_COUNT=$(jq 'length' "${API_KEYS_FILE}")
if [[ "${KEY_COUNT}" -eq 0 ]]; then
    log_info "No API keys configured."
    exit 0
fi

if [[ "${JSON_OUTPUT}" == "true" ]]; then
    # JSON output with masked keys
    jq -r 'to_entries | map({
        key_masked: (if (.key | length) > 12 then
            (.key | split("") | .[0:8] | join("")) + "..." + (.key | split("") | .[-4:] | join(""))
        else
            .key
        end),
        key_full: .key,
        name: .value.name,
        enabled: .value.enabled,
        rate_limit: .value.rate_limit
    })' "${API_KEYS_FILE}"
else
    # Table output
    printf '\n'
    printf '  %-28s  %-15s  %-8s  %-12s\n' "KEY" "NAME" "ENABLED" "RATE LIMIT"
    printf '  %-28s  %-15s  %-8s  %-12s\n' "----------------------------" "---------------" "--------" "------------"

    jq -r 'to_entries[] | [
        (if (.key | length) > 12 then
            (.key | split("") | .[0:8] | join("")) + "..." + (.key | split("") | .[-4:] | join(""))
        else
            .key
        end),
        .value.name,
        (if .value.enabled then "yes" else "no" end),
        (.value.rate_limit | tostring) + " req/min"
    ] | @tsv' "${API_KEYS_FILE}" | while IFS=$'\t' read -r key name enabled rate; do
        printf '  %-28s  %-15s  %-8s  %-12s\n' "${key}" "${name}" "${enabled}" "${rate}"
    done

    printf '\n'
    log_info "Total keys: ${KEY_COUNT}"
fi
