#!/usr/bin/env bash
# ==============================================================================
# test-endpoint.sh — Test the RPC gateway endpoint
#
# Usage:
#   ./scripts/rpc/test-endpoint.sh [OPTIONS]
#
# Options:
#   --key KEY           API key to use (default: first key in api-keys.json)
#   --method METHOD     RPC method to call (default: getblockchaininfo)
#   --network NETWORK   Target network: mainnet, signet, testnet (default: default route)
#   --params PARAMS     JSON params array (default: [])
#   --host HOST         Host to connect to (default: localhost)
#   --port PORT         Port to connect to (default: 80)
#   --header            Use X-API-Key header instead of URL path
#
# Makes a curl request to the local RPC endpoint and displays results.
# ==============================================================================
set -euo pipefail

# Source shared libraries
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_SCRIPT_DIR}/../lib/config-utils.sh"

# Require curl and jq
require_command curl "sudo apt install curl"
require_command jq "sudo apt install jq"

# Defaults
API_KEY=""
RPC_METHOD="getblockchaininfo"
NETWORK=""
RPC_PARAMS="[]"
HOST="localhost"
PORT="80"
USE_HEADER=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)
            API_KEY="${2:?--key requires a value}"
            shift 2
            ;;
        --method)
            RPC_METHOD="${2:?--method requires a value}"
            shift 2
            ;;
        --network)
            NETWORK="${2:?--network requires a value}"
            shift 2
            ;;
        --params)
            RPC_PARAMS="${2:?--params requires a value}"
            shift 2
            ;;
        --host)
            HOST="${2:?--host requires a value}"
            shift 2
            ;;
        --port)
            PORT="${2:?--port requires a value}"
            shift 2
            ;;
        --header)
            USE_HEADER=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: test-endpoint.sh [OPTIONS]

Test the RPC gateway endpoint.

Options:
  --key KEY           API key (default: first key in api-keys.json)
  --method METHOD     RPC method (default: getblockchaininfo)
  --network NETWORK   Target network: mainnet, signet, testnet
  --params PARAMS     JSON params array (default: [])
  --host HOST         Host (default: localhost)
  --port PORT         Port (default: 80)
  --header            Use X-API-Key header instead of URL path
  -h, --help          Show this help message

Examples:
  test-endpoint.sh                                    # Basic test with defaults
  test-endpoint.sh --method getblockcount             # Specific method
  test-endpoint.sh --network signet                   # Specific network
  test-endpoint.sh --key mk_live_abc123 --header      # Use header auth
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

# If no API key specified, try to get the first one from api-keys.json
if [[ -z "${API_KEY}" ]]; then
    API_KEYS_FILE="${PROJECT_ROOT}/config/openresty/api-keys.json"

    if [[ -f "${API_KEYS_FILE}" ]]; then
        API_KEY=$(jq -r 'keys[0] // empty' "${API_KEYS_FILE}" 2>/dev/null)
    fi

    if [[ -z "${API_KEY}" ]]; then
        log_error "No API key specified and none found in api-keys.json."
        log_error "Use --key KEY or run add-key.sh first."
        exit 1
    fi
    log_info "Using first key from api-keys.json: ${API_KEY:0:8}...${API_KEY: -4}"
fi

# Build URL
if [[ -n "${NETWORK}" ]]; then
    URL="http://${HOST}:${PORT}/v1/${API_KEY}/${NETWORK}"
else
    URL="http://${HOST}:${PORT}/v1/${API_KEY}"
fi

# Build JSON-RPC payload
PAYLOAD=$(jq -n \
    --arg method "${RPC_METHOD}" \
    --argjson params "${RPC_PARAMS}" \
    '{
        jsonrpc: "2.0",
        id: 1,
        method: $method,
        params: $params
    }')

# Display request info
echo ""
log_info "RPC Endpoint Test"
echo "  URL:     ${URL}"
echo "  Method:  ${RPC_METHOD}"
echo "  Params:  ${RPC_PARAMS}"
if [[ "${USE_HEADER}" == "true" ]]; then
    echo "  Auth:    X-API-Key header (${API_KEY:0:8}...${API_KEY: -4})"
else
    echo "  Auth:    URL path"
fi
echo ""

# Build curl command
CURL_ARGS=(
    -s
    -w '\n--- HTTP Status: %{http_code} | Time: %{time_total}s ---\n'
    -X POST
    -H "Content-Type: application/json"
)

if [[ "${USE_HEADER}" == "true" ]]; then
    CURL_ARGS+=(-H "X-API-Key: ${API_KEY}")
fi

CURL_ARGS+=(-d "${PAYLOAD}" "${URL}")

# Execute request
log_info "Sending request..."
echo ""

RESPONSE=$(curl "${CURL_ARGS[@]}" 2>&1) || true

# Try to pretty-print JSON response, fall back to raw output
BODY=$(echo "${RESPONSE}" | head -n -1)
STATUS_LINE=$(echo "${RESPONSE}" | tail -n 1)

if echo "${BODY}" | jq . 2>/dev/null; then
    : # jq already printed the formatted output
else
    echo "${BODY}"
fi

echo "${STATUS_LINE}"
echo ""
