#!/usr/bin/env bash
# ==============================================================================
# generate-config.sh — Core configuration generator for mempool.space stack
#
# Reads node.conf and renders all service configuration files from templates.
# This is the centerpiece of the configurator pattern:
#   wizard.sh -> node.conf -> generate-config.sh -> all configs
#
# Usage:
#   ./scripts/setup/generate-config.sh
#   ./scripts/setup/generate-config.sh --dry-run   # show what would be written
#
# DO NOT EDIT generated config files directly — re-run this script instead.
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Source shared libraries
# ==============================================================================
_GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_GEN_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_GEN_DIR}/../lib/config-utils.sh"
# shellcheck source=../lib/network-defaults.sh
source "${_GEN_DIR}/../lib/network-defaults.sh"

# ==============================================================================
# Paths
# ==============================================================================
TEMPLATE_DIR="${PROJECT_ROOT}/config/templates"
CONFIG_DIR="${PROJECT_ROOT}/config"

# Track all generated files for summary
declare -a GENERATED_FILES=()

# --dry-run support
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log_info "Dry-run mode: no files will be written."
fi

# ==============================================================================
# RPC Method Profiles
# ==============================================================================

# Read-only: safe, query-only methods
readonly -a RPC_METHODS_READ_ONLY=(
    getblockchaininfo
    getblock
    getblockhash
    getblockcount
    getblockheader
    getbestblockhash
    getdifficulty
    getchaintips
    getchaintxstats
    getmempoolinfo
    getrawmempool
    getmempoolentry
    getmempoolancestors
    getmempooldescendants
    gettxout
    gettxoutsetinfo
    getrawtransaction
    decoderawtransaction
    decodescript
    validateaddress
    estimatesmartfee
    getnetworkinfo
    getpeerinfo
    getconnectioncount
    getnettotals
    getindexinfo
    uptime
)

# Standard: read-only + transaction submission
readonly -a RPC_METHODS_STANDARD=(
    "${RPC_METHODS_READ_ONLY[@]}"
    sendrawtransaction
    testmempoolaccept
)

# Full: standard + wallet and advanced calls
readonly -a RPC_METHODS_FULL=(
    "${RPC_METHODS_STANDARD[@]}"
    getbalance
    gettransaction
    listtransactions
    listunspent
    getaddressinfo
    getwalletinfo
    listwallets
    createrawtransaction
    signrawtransactionwithkey
    fundrawtransaction
    combinepsbt
    finalizepsbt
    decodepsbt
    analyzepsbt
    deriveaddresses
    createmultisig
    getdescriptorinfo
    submitblock
    getblocktemplate
    getmininginfo
    getnetworkhashps
    prioritisetransaction
    logging
    getzmqnotifications
    echo
)

# ==============================================================================
# Helper: get_rpc_methods PROFILE
#   Returns the comma-separated method list for the given profile.
# ==============================================================================
get_rpc_methods() {
    local profile="${1:-read-only}"
    local -a methods

    case "${profile}" in
        read-only)  methods=("${RPC_METHODS_READ_ONLY[@]}") ;;
        standard)   methods=("${RPC_METHODS_STANDARD[@]}") ;;
        full)       methods=("${RPC_METHODS_FULL[@]}") ;;
        *)
            log_warn "Unknown RPC method profile '${profile}', falling back to read-only."
            methods=("${RPC_METHODS_READ_ONLY[@]}")
            ;;
    esac

    local IFS=','
    printf '%s' "${methods[*]}"
}

# ==============================================================================
# Helper: get_rpc_methods_lua PROFILE
#   Returns the method list as a Lua table literal for the Lua template.
# ==============================================================================
get_rpc_methods_lua() {
    local profile="${1:-read-only}"
    local -a methods

    case "${profile}" in
        read-only)  methods=("${RPC_METHODS_READ_ONLY[@]}") ;;
        standard)   methods=("${RPC_METHODS_STANDARD[@]}") ;;
        full)       methods=("${RPC_METHODS_FULL[@]}") ;;
        *)
            log_warn "Unknown RPC method profile '${profile}', falling back to read-only."
            methods=("${RPC_METHODS_READ_ONLY[@]}")
            ;;
    esac

    local result="{"
    local first=true
    local m
    for m in "${methods[@]}"; do
        if ${first}; then
            first=false
        else
            result+=", "
        fi
        result+="\"${m}\""
    done
    result+="}"

    printf '%s' "${result}"
}

# ==============================================================================
# Helper: render_template TEMPLATE_FILE NAMEREF_ASSOC_ARRAY
#   Reads a template, replaces all {{KEY}} placeholders with values from the
#   associative array, and prints the result to stdout.
#
#   Handles both single-line and multi-line replacement values.
# ==============================================================================
render_template() {
    local template="$1"
    local -n _tmpl_vars=$2

    if [[ ! -f "${template}" ]]; then
        log_error "Template not found: ${template}"
        return 1
    fi

    local content
    content=$(<"${template}")

    local key
    for key in "${!_tmpl_vars[@]}"; do
        local value="${_tmpl_vars[$key]}"

        # Check if value contains newlines (multi-line)
        if [[ "${value}" == *$'\n'* ]]; then
            # Multi-line replacement using awk
            # Replace the line containing {{KEY}} with the multi-line value
            local placeholder="{{${key}}}"
            content=$(awk -v placeholder="${placeholder}" -v replacement="${value}" '
            {
                idx = index($0, placeholder)
                if (idx > 0) {
                    # Get the prefix (indentation) before the placeholder
                    prefix = substr($0, 1, idx - 1)
                    suffix = substr($0, idx + length(placeholder))

                    # If the line is ONLY whitespace + placeholder (+ optional whitespace),
                    # print replacement lines with the same indentation
                    stripped = $0
                    gsub(/^[[:space:]]+/, "", stripped)
                    gsub(/[[:space:]]+$/, "", stripped)
                    if (stripped == placeholder) {
                        n = split(replacement, lines, "\n")
                        for (i = 1; i <= n; i++) {
                            print lines[i]
                        }
                    } else {
                        # Inline replacement: substitute placeholder in the line
                        gsub(placeholder, replacement)
                        print
                    }
                } else {
                    print
                }
            }' <<< "${content}")
        else
            # Single-line replacement using parameter expansion for safety
            # Loop to replace all occurrences
            local placeholder="{{${key}}}"
            while [[ "${content}" == *"${placeholder}"* ]]; do
                content="${content//"${placeholder}"/"${value}"}"
            done
        fi
    done

    printf '%s\n' "${content}"
}

# ==============================================================================
# Helper: write_file PATH CONTENT
#   Creates parent directories, writes content, and logs the action.
#   Respects --dry-run mode.
# ==============================================================================
write_file() {
    local filepath="$1"
    local content="$2"

    if ${DRY_RUN}; then
        log_info "[dry-run] Would write: ${filepath}"
    else
        mkdir -p "$(dirname "${filepath}")"
        printf '%s\n' "${content}" > "${filepath}"
        log_success "Wrote ${filepath}"
    fi

    GENERATED_FILES+=("${filepath}")
}

# ==============================================================================
# Helper: generate_rpcauth USER PASSWORD
#   Generates a Bitcoin Core rpcauth= line.
#   Uses Python 3 for HMAC-SHA256 computation (requires python3).
# ==============================================================================
generate_rpcauth() {
    local user="$1"
    local password="$2"

    if command -v python3 &>/dev/null; then
        python3 -c "
import hashlib, hmac, os
salt = os.urandom(16).hex()
password_hmac = hmac.new(
    salt.encode('utf-8'),
    '${password}'.encode('utf-8'),
    hashlib.sha256
).hexdigest()
print(f'rpcauth=${user}:{salt}\${password_hmac}')
"
    else
        # Fallback: use rpcuser/rpcpassword (less secure, but functional)
        log_warn "python3 not found; falling back to rpcuser/rpcpassword (rpcauth preferred)."
        printf 'rpcuser=%s\nrpcpassword=%s' "${user}" "${password}"
    fi
}

# ==============================================================================
# Helper: get_electrs_network NETWORK
#   Maps our network name to electrs network string.
# ==============================================================================
get_electrs_network() {
    local network="$1"
    case "${network}" in
        mainnet)  printf 'bitcoin' ;;
        signet)   printf 'signet' ;;
        testnet)  printf 'testnet' ;;
        *)        log_error "Unknown network: ${network}"; return 1 ;;
    esac
}

# Maps our network name to electrs CLI --network value (differs from toml config).
get_electrs_cli_network() {
    local network="$1"
    case "${network}" in
        mainnet)  printf 'mainnet' ;;
        signet)   printf 'signet' ;;
        testnet)  printf 'testnet' ;;
        *)        log_error "Unknown network: ${network}"; return 1 ;;
    esac
}

# ==============================================================================
# Helper: get_network_section NETWORK
#   Maps our network name to bitcoin.conf [section] name.
# ==============================================================================
get_network_section() {
    local network="$1"
    case "${network}" in
        mainnet)  printf 'main' ;;
        signet)   printf 'signet' ;;
        testnet)  printf 'test' ;;
        *)        log_error "Unknown network: ${network}"; return 1 ;;
    esac
}

# ==============================================================================
# Helper: get_mempool_network NETWORK
#   Maps our network name to Mempool backend NETWORK config value.
# ==============================================================================
get_mempool_network() {
    local network="$1"
    case "${network}" in
        mainnet)  printf '' ;;
        signet)   printf 'signet' ;;
        testnet)  printf 'testnet' ;;
        *)        log_error "Unknown network: ${network}"; return 1 ;;
    esac
}

# ==============================================================================
# Per-network config generators
# ==============================================================================

# generate_bitcoin_conf NETWORK
#   Renders config/{network}/bitcoin.conf from the template.
generate_bitcoin_conf() {
    local network="$1"

    get_default_ports "${network}"
    get_chain_params "${network}"

    local network_flag
    network_flag="$(get_bitcoin_network_flag "${network}")"

    local network_section
    network_section="$(get_network_section "${network}")"

    local rpc_user rpc_pass
    rpc_user="$(get_config BITCOIN_RPC_USER)"
    rpc_pass="$(get_config BITCOIN_RPC_PASS)"

    # Generate rpcauth line for internal services
    local rpc_auth_internal
    rpc_auth_internal="$(generate_rpcauth "${rpc_user}" "${rpc_pass}")"

    # RPC gateway auth (if RPC endpoint enabled)
    local rpc_auth_gateway=""
    local rpc_whitelist_gateway=""
    local rpc_whitelist_default=""
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"

    if [[ "${rpc_enabled}" == "true" ]]; then
        local gw_user gw_pass
        gw_user="$(get_config GATEWAY_RPC_USER gateway)"
        gw_pass="$(get_config GATEWAY_RPC_PASS)"

        if [[ -n "${gw_pass}" ]]; then
            rpc_auth_gateway="$(generate_rpcauth "${gw_user}" "${gw_pass}")"

            local method_profile
            method_profile="$(get_config RPC_METHOD_PROFILE read-only)"
            local methods
            methods="$(get_rpc_methods "${method_profile}")"
            rpc_whitelist_gateway="rpcwhitelist=${gw_user}:${methods}"
            rpc_whitelist_default="rpcwhitelistdefault=0"
        fi
    fi

    # If no gateway auth, add a comment placeholder
    if [[ -z "${rpc_auth_gateway}" ]]; then
        rpc_auth_gateway="# (RPC gateway not enabled)"
        rpc_whitelist_gateway="# (no whitelist — gateway not enabled)"
        rpc_whitelist_default="# (rpcwhitelistdefault not set — all methods allowed for all users)"
    fi

    local txindex prune dbcache maxmempool maxconnections
    txindex="$(get_config TXINDEX 1)"
    prune="$(get_config PRUNE 0)"
    dbcache="$(get_config DBCACHE 2048)"
    maxmempool="$(get_config MAXMEMPOOL 300)"
    maxconnections="$(get_config MAXCONNECTIONS 40)"
    rpcworkqueue="$(get_config RPCWORKQUEUE 128)"
    rpcthreads="$(get_config RPCTHREADS 8)"

    # Map boolean-style txindex to 0/1
    case "${txindex}" in
        true|yes|1)  txindex=1 ;;
        false|no|0)  txindex=0 ;;
    esac

    declare -A btc_vars=(
        [NETWORK_NAME]="${CHAIN_NAME}"
        [NETWORK_FLAG]="${network_flag}"
        [NETWORK_SECTION]="${network_section}"
        [TXINDEX]="${txindex}"
        [PRUNE]="${prune}"
        [RPC_PORT]="${CHAIN_RPC_PORT}"
        [RPC_BIND]="0.0.0.0"
        [RPC_ALLOWIP]="172.16.0.0/12"
        [RPC_AUTH_INTERNAL]="${rpc_auth_internal}"
        [RPC_AUTH_GATEWAY]="${rpc_auth_gateway}"
        [RPC_WHITELIST_GATEWAY]="${rpc_whitelist_gateway}"
        [RPC_WHITELIST_DEFAULT]="${rpc_whitelist_default}"
        [DBCACHE]="${dbcache}"
        [MAXMEMPOOL]="${maxmempool}"
        [MAXCONNECTIONS]="${maxconnections}"
        [RPCWORKQUEUE]="${rpcworkqueue}"
        [RPCTHREADS]="${rpcthreads}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/bitcoin.conf.tmpl" btc_vars)"

    write_file "${CONFIG_DIR}/${network}/bitcoin.conf" "${output}"
}

# generate_electrs_conf NETWORK
#   Renders config/{network}/electrs.toml from the template.
generate_electrs_conf() {
    local network="$1"

    get_default_ports "${network}"
    get_chain_params "${network}"

    local electrs_network
    electrs_network="$(get_electrs_network "${network}")"

    local rpc_user rpc_pass
    rpc_user="$(get_config BITCOIN_RPC_USER)"
    rpc_pass="$(get_config BITCOIN_RPC_PASS)"

    declare -A electrs_vars=(
        [NETWORK_NAME]="${CHAIN_NAME}"
        [ELECTRS_NETWORK]="${electrs_network}"
        [NETWORK]="${network}"
        [RPC_PORT]="${CHAIN_RPC_PORT}"
        [P2P_PORT]="${CHAIN_P2P_PORT}"
        [RPC_USER]="${rpc_user}"
        [RPC_PASS]="${rpc_pass}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/electrs.toml.tmpl" electrs_vars)"

    write_file "${CONFIG_DIR}/${network}/electrs.toml" "${output}"
}

# generate_mempool_conf NETWORK
#   Renders config/{network}/mempool-config.json from the template.
generate_mempool_conf() {
    local network="$1"

    get_default_ports "${network}"
    get_chain_params "${network}"

    local mempool_network
    mempool_network="$(get_mempool_network "${network}")"

    local rpc_user rpc_pass mariadb_user mariadb_pass
    rpc_user="$(get_config BITCOIN_RPC_USER)"
    rpc_pass="$(get_config BITCOIN_RPC_PASS)"
    mariadb_user="$(get_config MARIADB_USER mempool)"
    mariadb_pass="$(get_config MARIADB_PASS)"

    declare -A mempool_vars=(
        [NETWORK]="${mempool_network}"
        [BITCOIN_RPC_HOST]="bitcoind-${network}"
        [BITCOIN_RPC_PORT]="${CHAIN_RPC_PORT}"
        [BITCOIN_RPC_USER]="${rpc_user}"
        [BITCOIN_RPC_PASS]="${rpc_pass}"
        [ELECTRS_HOST]="electrs-${network}"
        [ELECTRS_PORT]="50001"
        [MARIADB_HOST]="mariadb"
        [MARIADB_PORT]="3306"
        [MARIADB_DATABASE]="${CHAIN_DB_NAME}"
        [MARIADB_USER]="${mariadb_user}"
        [MARIADB_PASS]="${mariadb_pass}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/mempool-config.json.tmpl" mempool_vars)"

    write_file "${CONFIG_DIR}/${network}/mempool-config.json" "${output}"
}

# ==============================================================================
# Shared config generators
# ==============================================================================

# generate_mariadb_init
#   Renders config/mariadb/init/01-init.sql from the template.
#   Note: Docker entrypoint only runs init scripts on first MariaDB start.
#   If networks are added later, start.sh will apply the init SQL to ensure
#   new databases exist. The SQL is idempotent (CREATE DATABASE IF NOT EXISTS).
generate_mariadb_init() {
    local mariadb_user
    mariadb_user="$(get_config MARIADB_USER mempool)"

    local db_creates=""
    local net
    for net in "${networks[@]}"; do
        get_chain_params "${net}"
        db_creates+="CREATE DATABASE IF NOT EXISTS \`${CHAIN_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        db_creates+=$'\n'
        db_creates+="GRANT ALL PRIVILEGES ON \`${CHAIN_DB_NAME}\`.* TO '${mariadb_user}'@'%';"
        db_creates+=$'\n'
    done
    db_creates+="FLUSH PRIVILEGES;"

    declare -A mariadb_vars=(
        [DATABASE_CREATES]="${db_creates}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/mariadb-init.sql.tmpl" mariadb_vars)"

    write_file "${CONFIG_DIR}/mariadb/init/01-init.sql" "${output}"
}

# generate_nginx_conf
#   Renders config/openresty/nginx.conf from the template.
generate_nginx_conf() {
    local server_name
    server_name="$(get_config DOMAIN_WEB _)"

    # --- Build upstream blocks ---
    local upstream_blocks=""
    local net
    for net in "${networks[@]}"; do
        upstream_blocks+="    upstream mempool-api-${net} {"$'\n'
        upstream_blocks+="        server mempool-api-${net}:8999;"$'\n'
        upstream_blocks+="    }"$'\n'
        upstream_blocks+="    upstream electrs-${net} {"$'\n'
        upstream_blocks+="        server electrs-${net}:3003;"$'\n'
        upstream_blocks+="    }"$'\n'
    done
    upstream_blocks+="    upstream mempool-web {"$'\n'
    upstream_blocks+="        server mempool-web:8080;"$'\n'
    upstream_blocks+="    }"

    # --- Helper: generate API location blocks for a network ---
    #
    # Matches the official mempool.space production nginx routing:
    #   /api/v1/*  → mempool backend (port 8999)
    #   /api/*     → electrs HTTP API (port 3003) directly
    #
    # The frontend uses /api/v1/ for mempool-specific endpoints (fees,
    # mining, statistics, websockets) and /api/ (no v1) for esplora/
    # electrs endpoints (block txs, address txs, tx details, etc.).
    _api_locations() {
        local net="$1"        # e.g. "mainnet" or "signet"
        local prefix="$2"     # URL prefix: "" for mainnet, "/${net}" for others
        local out=""

        local backend="mempool-api-${net}"
        local electrs="electrs-${net}"

        # --- mempool backend routes (/api/v1/*) ---

        # Websocket
        out+="        location ${prefix}/api/v1/ws {"$'\n'
        out+="            rewrite ^${prefix}/api/v1/ws(.*) /api/v1/ws\$1 break;"$'\n'
        out+="            proxy_pass http://${backend};"$'\n'
        out+="            proxy_http_version 1.1;"$'\n'
        out+="            proxy_set_header Upgrade \$http_upgrade;"$'\n'
        out+="            proxy_set_header Connection \"upgrade\";"$'\n'
        out+="            proxy_set_header Host \$host;"$'\n'
        out+="        }"$'\n'
        out+=$'\n'

        # /api/v1/ → mempool backend
        out+="        location ${prefix}/api/v1 {"$'\n'
        out+="            rewrite ^${prefix}/api/v1(.*) /api/v1\$1 break;"$'\n'
        out+="            proxy_pass http://${backend};"$'\n'
        out+="            proxy_set_header Host \$host;"$'\n'
        out+="            proxy_set_header X-Real-IP \$remote_addr;"$'\n'
        out+="            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"$'\n'
        out+="            proxy_set_header X-Forwarded-Proto \$scheme;"$'\n'
        out+="        }"$'\n'
        out+=$'\n'

        # --- electrs/esplora routes (/api/* without v1) ---

        # /api/ → electrs HTTP API directly (strips prefix, no v1 rewrite)
        out+="        location ${prefix}/api/ {"$'\n'
        out+="            rewrite ^${prefix}/api/(.*) /\$1 break;"$'\n'
        out+="            proxy_pass http://${electrs};"$'\n'
        out+="            proxy_set_header Host \$host;"$'\n'
        out+="            proxy_set_header X-Real-IP \$remote_addr;"$'\n'
        out+="            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"$'\n'
        out+="            proxy_set_header X-Forwarded-Proto \$scheme;"$'\n'
        out+="        }"$'\n'

        echo -n "${out}"
    }

    # --- Build mainnet API locations ---
    local mainnet_api_locations=""
    if is_network_enabled mainnet; then
        mainnet_api_locations="$(_api_locations "mainnet" "")"
    else
        mainnet_api_locations="        # (mainnet not enabled)"
    fi

    # --- Build non-mainnet API locations ---
    local network_api_locations=""
    for net in "${networks[@]}"; do
        [[ "${net}" == "mainnet" ]] && continue
        network_api_locations+="$(_api_locations "${net}" "/${net}")"
        network_api_locations+=$'\n'
    done

    if [[ -z "${network_api_locations}" ]]; then
        network_api_locations="        # (no additional networks)"
    else
        # Trim trailing newline
        network_api_locations="${network_api_locations%$'\n'}"
    fi

    # --- Build RPC server block ---
    local rpc_server_block=""
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    if [[ "${rpc_enabled}" == "true" ]]; then
        local rpc_port
        rpc_port="$(get_config RPC_PORT 3000)"

        local gw_user gw_pass basic_auth
        gw_user="$(get_config GATEWAY_RPC_USER gateway)"
        gw_pass="$(get_config GATEWAY_RPC_PASS)"
        basic_auth="$(printf '%s:%s' "${gw_user}" "${gw_pass}" | base64 -w0)"

        # CORS headers shared across all RPC locations
        local cors_headers=""
        cors_headers+="            add_header Access-Control-Allow-Origin \"*\" always;"$'\n'
        cors_headers+="            add_header Access-Control-Allow-Methods \"POST, OPTIONS\" always;"$'\n'
        cors_headers+="            add_header Access-Control-Allow-Headers \"Content-Type, X-API-Key\" always;"$'\n'

        # Shared proxy settings for all RPC locations
        local proxy_common=""
        proxy_common+="            proxy_set_header Authorization \"Basic ${basic_auth}\";"$'\n'
        proxy_common+="            proxy_set_header Content-Type application/json;"$'\n'
        proxy_common+="            proxy_http_version 1.1;"$'\n'
        proxy_common+="            proxy_set_header Connection \"\";"

        # Helper: emit a single RPC location block
        # _rpc_location_block LOCATION_PATH BITCOIND_HOST RPC_PORT
        _rpc_location_block() {
            local loc_path="$1"
            local btc_host="$2"
            local btc_rpc_port="$3"
            local block=""
            block+="        location ~ ^${loc_path}$ {"$'\n'
            block+="            access_by_lua_file /etc/openresty/jsonrpc-access.lua;"$'\n'
            block+="${cors_headers}"
            block+=$'\n'
            block+="            # Handle CORS preflight"$'\n'
            block+="            if (\$request_method = OPTIONS) {"$'\n'
            block+="                add_header Access-Control-Allow-Origin \"*\";"$'\n'
            block+="                add_header Access-Control-Allow-Methods \"POST, OPTIONS\";"$'\n'
            block+="                add_header Access-Control-Allow-Headers \"Content-Type, X-API-Key\";"$'\n'
            block+="                add_header Content-Length 0;"$'\n'
            block+="                add_header Content-Type text/plain;"$'\n'
            block+="                return 204;"$'\n'
            block+="            }"$'\n'
            block+=$'\n'
            block+="            set \$backend_uri http://${btc_host}:${btc_rpc_port}/;"$'\n'
            block+="            proxy_pass \$backend_uri;"$'\n'
            block+="${proxy_common}"$'\n'
            block+="        }"
            printf '%s' "${block}"
        }

        rpc_server_block+="    server {"$'\n'
        rpc_server_block+="        listen ${rpc_port};"$'\n'
        rpc_server_block+="        server_name _;"$'\n'
        rpc_server_block+=$'\n'
        rpc_server_block+="        # Docker embedded DNS (required for variable-based proxy_pass)"$'\n'
        rpc_server_block+="        resolver 127.0.0.11 valid=30s;"$'\n'

        # Default RPC route: /v2/{key} → primary network's bitcoind
        local primary_net="${networks[0]}"
        get_chain_params "${primary_net}"
        local primary_rpc_port="${CHAIN_RPC_PORT}"

        rpc_server_block+=$'\n'
        rpc_server_block+="$(_rpc_location_block "/v2/[^/]+" "bitcoind-${primary_net}" "${primary_rpc_port}")"

        # Per-network explicit routes: /v2/{key}/{network}
        local rpc_net
        for rpc_net in "${networks[@]}"; do
            get_chain_params "${rpc_net}"
            rpc_server_block+=$'\n\n'
            rpc_server_block+="$(_rpc_location_block "/v2/[^/]+/${rpc_net}" "bitcoind-${rpc_net}" "${CHAIN_RPC_PORT}")"
        done

        rpc_server_block+=$'\n\n'
        rpc_server_block+="        location / {"$'\n'
        rpc_server_block+="            content_by_lua_block {"$'\n'
        rpc_server_block+="                local accept = ngx.req.get_headers()[\"Accept\"] or \"\""$'\n'
        rpc_server_block+="                if accept:find(\"text/html\") then"$'\n'
        rpc_server_block+="                    ngx.header[\"Content-Type\"] = \"text/html\""$'\n'
        rpc_server_block+="                    ngx.say([=["$'\n'
        rpc_server_block+="<!DOCTYPE html><html><head><title>Bitcoin RPC Gateway</title>"$'\n'
        rpc_server_block+="<style>"$'\n'
        rpc_server_block+="body{font-family:system-ui,sans-serif;max-width:600px;margin:80px auto;padding:0 20px;color:#333;background:#f8f8f8}"$'\n'
        rpc_server_block+="h1{color:#f7931a}"$'\n'
        rpc_server_block+="pre{background:#2d2d2d;color:#f8f8f2;padding:16px;border-radius:6px;overflow-x:auto}"$'\n'
        rpc_server_block+="</style></head><body>"$'\n'
        rpc_server_block+="<h1>Bitcoin RPC Gateway</h1>"$'\n'
        rpc_server_block+="<p>This is a JSON-RPC endpoint. Send POST requests to:</p>"$'\n'
        rpc_server_block+="<pre>POST /v2/{api-key}</pre>"$'\n'
        rpc_server_block+="<p>Example:</p>"$'\n'
        rpc_server_block+="<pre>curl -X POST https://host/v2/{api-key} \\"$'\n'
        rpc_server_block+="  -H \"Content-Type: application/json\" \\"$'\n'
        rpc_server_block+="  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockchaininfo\",\"params\":[]}'</pre>"$'\n'
        rpc_server_block+="</body></html>"$'\n'
        rpc_server_block+="                    ]=])"$'\n'
        rpc_server_block+="                else"$'\n'
        rpc_server_block+="                    ngx.header[\"Content-Type\"] = \"application/json\""$'\n'
        rpc_server_block+="                    ngx.status = 404"$'\n'
        rpc_server_block+="                    ngx.say('{\"error\":\"Not found\",\"usage\":\"POST /v2/{api-key}\"}')"$'\n'
        rpc_server_block+="                end"$'\n'
        rpc_server_block+="            }"$'\n'
        rpc_server_block+="        }"$'\n'
        rpc_server_block+="    }"

        # Clean up the helper function
        unset -f _rpc_location_block
    else
        rpc_server_block="    # (RPC server block not enabled)"
    fi

    # --- Build SSL config ---
    local ssl_config=""
    local tls_mode
    tls_mode="$(get_config TLS_MODE none)"
    case "${tls_mode}" in
        self-signed)
            ssl_config+="        listen 443 ssl;"$'\n'
            ssl_config+="        ssl_certificate /etc/openresty/ssl/server.crt;"$'\n'
            ssl_config+="        ssl_certificate_key /etc/openresty/ssl/server.key;"
            ;;
        letsencrypt)
            ssl_config+="        listen 443 ssl;"$'\n'
            ssl_config+="        ssl_certificate /etc/letsencrypt/live/${server_name}/fullchain.pem;"$'\n'
            ssl_config+="        ssl_certificate_key /etc/letsencrypt/live/${server_name}/privkey.pem;"
            ;;
        *)
            ssl_config="        # (TLS not enabled)"
            ;;
    esac

    declare -A nginx_vars=(
        [UPSTREAM_BLOCKS]="${upstream_blocks}"
        [SSL_CONFIG]="${ssl_config}"
        [SERVER_NAME]="${server_name}"
        [MAINNET_API_LOCATIONS]="${mainnet_api_locations}"
        [NETWORK_API_LOCATIONS]="${network_api_locations}"
        [RPC_SERVER_BLOCK]="${rpc_server_block}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/openresty-nginx.conf.tmpl" nginx_vars)"

    write_file "${CONFIG_DIR}/openresty/nginx.conf" "${output}"
}

# generate_lua_script
#   Renders config/openresty/jsonrpc-access.lua from the template.
generate_lua_script() {
    local method_profile
    method_profile="$(get_config RPC_METHOD_PROFILE read-only)"

    local lua_methods
    lua_methods="$(get_rpc_methods_lua "${method_profile}")"

    declare -A lua_vars=(
        [API_KEYS_PATH]="/etc/openresty/api-keys.json"
        [WHITELISTED_METHODS]="${lua_methods}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/jsonrpc-access.lua.tmpl" lua_vars)"

    write_file "${CONFIG_DIR}/openresty/jsonrpc-access.lua" "${output}"
}

# generate_api_keys
#   Writes config/openresty/api-keys.json from node.conf values.
generate_api_keys() {
    local api_key
    api_key="$(get_config RPC_API_KEY "")"

    local rate_limit
    rate_limit="$(get_config RPC_RATE_LIMIT 60)"

    if [[ -z "${api_key}" ]]; then
        log_warn "RPC_ENDPOINT_ENABLED is true but RPC_API_KEY is not set; generating empty api-keys.json."
        write_file "${CONFIG_DIR}/openresty/api-keys.json" '{}'
        return 0
    fi

    # Build JSON with the configured API key
    local json_content
    json_content=$(cat <<APIEOF
{
  "${api_key}": {
    "name": "default",
    "enabled": true,
    "rate_limit": ${rate_limit}
  }
}
APIEOF
    )

    write_file "${CONFIG_DIR}/openresty/api-keys.json" "${json_content}"
}

# generate_cloudflared
#   Renders config/cloudflared/config.yml from the template.
generate_cloudflared() {
    local tunnel_token
    tunnel_token="$(get_config CLOUDFLARE_TUNNEL_TOKEN "")"

    local cf_hostname_web
    cf_hostname_web="$(get_config CF_HOSTNAME_WEB mempool.example.com)"

    local cf_hostname_rpc
    cf_hostname_rpc="$(get_config CF_HOSTNAME_RPC "")"

    local web_port
    web_port="$(get_config WEB_PORT 80)"

    # Build ingress rules
    local ingress_rules=""
    ingress_rules+="  - hostname: ${cf_hostname_web}"$'\n'
    ingress_rules+="    service: http://localhost:${web_port}"

    # Add RPC hostname if enabled and configured
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    if [[ "${rpc_enabled}" == "true" ]] && [[ -n "${cf_hostname_rpc}" ]]; then
        local rpc_port
        rpc_port="$(get_config RPC_PORT 3000)"
        ingress_rules+=$'\n'
        ingress_rules+="  - hostname: ${cf_hostname_rpc}"$'\n'
        ingress_rules+="    service: http://localhost:${rpc_port}"
    fi

    declare -A cf_vars=(
        [TUNNEL_ID]="${tunnel_token}"
        [INGRESS_RULES]="${ingress_rules}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/cloudflared-config.yml.tmpl" cf_vars)"

    write_file "${CONFIG_DIR}/cloudflared/config.yml" "${output}"
}

# ==============================================================================
# Docker Compose generator
# ==============================================================================

# _compose_security_block INDENT
#   Returns the standard security settings for all containers.
_compose_security_block() {
    local indent="${1:-    }"
    local block=""
    block+="${indent}restart: unless-stopped"$'\n'
    block+="${indent}security_opt:"$'\n'
    block+="${indent}  - no-new-privileges:true"$'\n'
    block+="${indent}cap_drop:"$'\n'
    block+="${indent}  - ALL"$'\n'
    block+="${indent}cap_add:"$'\n'
    block+="${indent}  - NET_BIND_SERVICE"
    printf '%s' "${block}"
}

# generate_compose
#   Builds and writes docker-compose.yml from the template.
generate_compose() {
    local storage_path
    storage_path="$(get_config STORAGE_PATH /data/mempool)"

    # Set version variables so get_docker_image picks them up
    BITCOIN_VERSION="$(get_config BITCOIN_VERSION "")"
    MEMPOOL_VERSION="$(get_config MEMPOOL_VERSION "")"
    ELECTRS_VERSION="$(get_config ELECTRS_VERSION "")"
    MARIADB_VERSION="$(get_config MARIADB_VERSION "")"
    OPENRESTY_VERSION="$(get_config OPENRESTY_VERSION "")"

    local bind_ip
    bind_ip="$(get_config BIND_IP "127.0.0.1")"

    local mariadb_root_pass mariadb_user mariadb_pass
    mariadb_root_pass="$(get_config MARIADB_ROOT_PASS)"
    mariadb_user="$(get_config MARIADB_USER mempool)"
    mariadb_pass="$(get_config MARIADB_PASS)"

    local security_block
    security_block="$(_compose_security_block "    ")"

    # ==== Build per-network services ====
    # TODO: Currently uses a single global indexer (electrs) for all networks.
    # Future: support per-network indexer choice (e.g., Fulcrum for mainnet,
    # Electrs for signet/testnet). Would require {NET}_INDEXER config keys and
    # conditional template/image selection in this loop.
    local network_services=""
    local net
    for net in "${networks[@]}"; do
        get_default_ports "${net}"
        get_chain_params "${net}"

        local bitcoin_version electrs_image mempool_api_image
        bitcoin_version="${BITCOIN_VERSION:-${RECOMMENDED_BITCOIN_VERSION}}"
        electrs_image="$(get_docker_image electrs)"
        mempool_api_image="$(get_docker_image mempool-api)"

        # --- bitcoind ---
        network_services+="  bitcoind-${net}:"$'\n'
        network_services+="    build:"$'\n'
        network_services+="      context: ."$'\n'
        network_services+="      dockerfile: docker/Dockerfile.bitcoin"$'\n'
        network_services+="      args:"$'\n'
        network_services+="        BITCOIN_VERSION: \"${bitcoin_version}\""$'\n'
        network_services+="    container_name: bitcoind-${net}"$'\n'
        network_services+="    volumes:"$'\n'
        network_services+="      - ${storage_path}/${net}/bitcoin:/data/.bitcoin"$'\n'
        network_services+="      - ./config/${net}/bitcoin.conf:/data/.bitcoin/bitcoin.conf:ro"$'\n'
        network_services+="    ports:"$'\n'
        network_services+="      - \"${bind_ip}:${CHAIN_P2P_PORT}:${CHAIN_P2P_PORT}\""$'\n'
        network_services+="    expose:"$'\n'
        network_services+="      - \"${CHAIN_RPC_PORT}\""$'\n'
        network_services+="    healthcheck:"$'\n'
        network_services+="      test: [\"CMD\", \"bitcoin-cli\", \"-datadir=/data/.bitcoin\", \"-rpcport=${CHAIN_RPC_PORT}\", \"getblockchaininfo\"]"$'\n'
        network_services+="      interval: 30s"$'\n'
        network_services+="      timeout: 10s"$'\n'
        network_services+="      retries: 5"$'\n'
        network_services+="      start_period: 600s"$'\n'
        network_services+="    networks:"$'\n'
        network_services+="      - mempool_net"$'\n'
        network_services+="${security_block}"$'\n'
        network_services+=$'\n'

        # --- electrs ---
        local electrs_network
        electrs_network="$(get_electrs_cli_network "${net}")"
        local rpc_user rpc_pass
        rpc_user="$(get_config BITCOIN_RPC_USER)"
        rpc_pass="$(get_config BITCOIN_RPC_PASS)"

        # Allow per-network data path override (e.g. ELECTRS_SIGNET_DATA_PATH=/RUST/electrs-signet)
        local net_upper electrs_data_path
        net_upper="$(echo "${net}" | tr '[:lower:]' '[:upper:]')"
        electrs_data_path="$(get_config "ELECTRS_${net_upper}_DATA_PATH" "")"
        if [[ -z "${electrs_data_path}" ]]; then
            electrs_data_path="${storage_path}/${net}/electrs"
        fi

        network_services+="  electrs-${net}:"$'\n'
        network_services+="    image: ${electrs_image}"$'\n'
        network_services+="    container_name: electrs-${net}"$'\n'
        network_services+="    command:"$'\n'
        network_services+="      - --network"$'\n'
        network_services+="      - ${electrs_network}"$'\n'
        network_services+="      - --daemon-rpc-addr"$'\n'
        network_services+="      - bitcoind-${net}:${CHAIN_RPC_PORT}"$'\n'
        network_services+="      - --electrum-rpc-addr"$'\n'
        network_services+="      - 0.0.0.0:50001"$'\n'
        network_services+="      - --db-dir"$'\n'
        network_services+="      - /data"$'\n'
        network_services+="      - --cookie"$'\n'
        network_services+="      - ${rpc_user}:${rpc_pass}"$'\n'
        network_services+="      - --http-addr"$'\n'
        network_services+="      - 0.0.0.0:3003"$'\n'
        network_services+="      - --rest-default-chain-txs-per-page"$'\n'
        network_services+="      - \"10\""$'\n'
        network_services+="      - --jsonrpc-import"$'\n'
        network_services+="    depends_on:"$'\n'
        network_services+="      bitcoind-${net}:"$'\n'
        network_services+="        condition: service_healthy"$'\n'
        network_services+="    volumes:"$'\n'
        network_services+="      - ${electrs_data_path}:/data/${electrs_network}"$'\n'
        network_services+="    expose:"$'\n'
        network_services+="      - \"50001\""$'\n'
        network_services+="      - \"3003\""$'\n'
        network_services+="    networks:"$'\n'
        network_services+="      - mempool_net"$'\n'
        network_services+="${security_block}"$'\n'
        network_services+=$'\n'

        # --- mempool-api ---
        network_services+="  mempool-api-${net}:"$'\n'
        network_services+="    image: ${mempool_api_image}"$'\n'
        network_services+="    container_name: mempool-api-${net}"$'\n'
        network_services+="    depends_on:"$'\n'
        network_services+="      electrs-${net}:"$'\n'
        network_services+="        condition: service_started"$'\n'
        network_services+="      mariadb:"$'\n'
        network_services+="        condition: service_healthy"$'\n'
        network_services+="    volumes:"$'\n'
        network_services+="      - ${storage_path}/${net}/mempool-cache:/backend/cache"$'\n'
        network_services+="      - ./config/${net}/mempool-config.json:/backend/mempool-config.json:ro"$'\n'
        network_services+="    expose:"$'\n'
        network_services+="      - \"8999\""$'\n'
        network_services+="    networks:"$'\n'
        network_services+="      - mempool_net"$'\n'
        network_services+="${security_block}"$'\n'
        network_services+=$'\n'
    done

    # Remove trailing newline
    network_services="${network_services%$'\n'}"

    # ==== Build shared services ====
    local shared_services=""

    # --- mariadb ---
    local mariadb_image
    mariadb_image="$(get_docker_image mariadb)"

    shared_services+="  mariadb:"$'\n'
    shared_services+="    image: ${mariadb_image}"$'\n'
    shared_services+="    container_name: mariadb"$'\n'
    shared_services+="    environment:"$'\n'
    shared_services+="      MYSQL_ROOT_PASSWORD: \"${mariadb_root_pass}\""$'\n'
    shared_services+="      MYSQL_USER: \"${mariadb_user}\""$'\n'
    shared_services+="      MYSQL_PASSWORD: \"${mariadb_pass}\""$'\n'
    shared_services+="    volumes:"$'\n'
    shared_services+="      - ${storage_path}/mariadb:/var/lib/mysql"$'\n'
    shared_services+="      - ./config/mariadb/init:/docker-entrypoint-initdb.d:ro"$'\n'
    shared_services+="    expose:"$'\n'
    shared_services+="      - \"3306\""$'\n'
    shared_services+="    healthcheck:"$'\n'
    shared_services+="      test: [\"CMD\", \"healthcheck.sh\", \"--connect\", \"--innodb_initialized\"]"$'\n'
    shared_services+="      interval: 10s"$'\n'
    shared_services+="      timeout: 5s"$'\n'
    shared_services+="      retries: 10"$'\n'
    shared_services+="      start_period: 30s"$'\n'
    shared_services+="    networks:"$'\n'
    shared_services+="      - mempool_net"$'\n'
    shared_services+="    restart: unless-stopped"$'\n'
    shared_services+="    security_opt:"$'\n'
    shared_services+="      - no-new-privileges:true"$'\n'
    shared_services+="    cap_drop:"$'\n'
    shared_services+="      - ALL"$'\n'
    shared_services+="    cap_add:"$'\n'
    shared_services+="      - CHOWN"$'\n'
    shared_services+="      - SETUID"$'\n'
    shared_services+="      - SETGID"$'\n'
    shared_services+="      - DAC_OVERRIDE"$'\n'
    shared_services+=$'\n'

    # --- mempool-web ---
    local mempool_web_image
    mempool_web_image="$(get_docker_image mempool-web)"

    # Build frontend env vars: backend hosts + network enable flags
    local frontend_env=""
    for net in "${networks[@]}"; do
        local net_upper="${net^^}"
        frontend_env+="      BACKEND_${net_upper}_HTTP_HOST: \"mempool-api-${net}\""$'\n'
        frontend_env+="      ${net_upper}_ENABLED: \"true\""$'\n'
    done
    # Trim trailing newline
    frontend_env="${frontend_env%$'\n'}"

    shared_services+="  mempool-web:"$'\n'
    shared_services+="    image: ${mempool_web_image}"$'\n'
    shared_services+="    container_name: mempool-web"$'\n'
    shared_services+="    environment:"$'\n'
    shared_services+="${frontend_env}"$'\n'
    shared_services+="    depends_on:"$'\n'
    for net in "${networks[@]}"; do
        shared_services+="      mempool-api-${net}:"$'\n'
        shared_services+="        condition: service_started"$'\n'
    done
    shared_services+="    expose:"$'\n'
    shared_services+="      - \"8080\""$'\n'
    shared_services+="    networks:"$'\n'
    shared_services+="      - mempool_net"$'\n'
    shared_services+="${security_block}"$'\n'
    shared_services+=$'\n'

    # --- openresty ---
    local openresty_image
    openresty_image="$(get_docker_image openresty)"

    local web_port
    web_port="$(get_config WEB_PORT 80)"

    local openresty_volumes=""
    openresty_volumes+="      - ./config/openresty/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro"$'\n'

    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    if [[ "${rpc_enabled}" == "true" ]]; then
        openresty_volumes+="      - ./config/openresty/jsonrpc-access.lua:/etc/openresty/jsonrpc-access.lua:ro"$'\n'
        openresty_volumes+="      - ./config/openresty/api-keys.json:/etc/openresty/api-keys.json:ro"$'\n'
    fi

    # TLS volumes
    local tls_mode
    tls_mode="$(get_config TLS_MODE none)"
    if [[ "${tls_mode}" == "self-signed" ]]; then
        openresty_volumes+="      - ./config/openresty/ssl:/etc/openresty/ssl:ro"$'\n'
    elif [[ "${tls_mode}" == "letsencrypt" ]]; then
        openresty_volumes+="      - /etc/letsencrypt:/etc/letsencrypt:ro"$'\n'
    fi

    # Trim trailing newline
    openresty_volumes="${openresty_volumes%$'\n'}"

    local openresty_ports=""
    openresty_ports+="      - \"${bind_ip}:${web_port}:80\""
    if [[ "${tls_mode}" != "none" ]]; then
        openresty_ports+=$'\n'
        openresty_ports+="      - \"${bind_ip}:443:443\""
    fi
    if [[ "${rpc_enabled}" == "true" ]]; then
        local rpc_port
        rpc_port="$(get_config RPC_PORT 3000)"
        openresty_ports+=$'\n'
        openresty_ports+="      - \"${bind_ip}:${rpc_port}:${rpc_port}\""
    fi

    shared_services+="  openresty:"$'\n'
    shared_services+="    image: ${openresty_image}"$'\n'
    shared_services+="    container_name: openresty"$'\n'
    shared_services+="    depends_on:"$'\n'
    shared_services+="      mempool-web:"$'\n'
    shared_services+="        condition: service_started"$'\n'
    for net in "${networks[@]}"; do
        shared_services+="      mempool-api-${net}:"$'\n'
        shared_services+="        condition: service_started"$'\n'
    done
    shared_services+="    ports:"$'\n'
    shared_services+="${openresty_ports}"$'\n'
    shared_services+="    volumes:"$'\n'
    shared_services+="${openresty_volumes}"$'\n'
    shared_services+="    networks:"$'\n'
    shared_services+="      - mempool_net"$'\n'
    shared_services+="    restart: unless-stopped"$'\n'
    shared_services+="    security_opt:"$'\n'
    shared_services+="      - no-new-privileges:true"$'\n'
    shared_services+="    cap_drop:"$'\n'
    shared_services+="      - ALL"$'\n'
    shared_services+="    cap_add:"$'\n'
    shared_services+="      - CHOWN"$'\n'
    shared_services+="      - SETUID"$'\n'
    shared_services+="      - SETGID"$'\n'
    shared_services+="      - NET_BIND_SERVICE"

    # --- cloudflared (conditional) ---
    local tunnel_enabled
    tunnel_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED false)"
    if [[ "${tunnel_enabled}" == "true" ]]; then
        local tunnel_token
        tunnel_token="$(get_config CLOUDFLARE_TUNNEL_TOKEN "")"

        shared_services+=$'\n'
        shared_services+=$'\n'
        shared_services+="  cloudflared:"$'\n'
        shared_services+="    image: $(get_docker_image cloudflared)"$'\n'
        shared_services+="    container_name: cloudflared"$'\n'
        shared_services+="    command: tunnel run --token ${tunnel_token}"$'\n'
        shared_services+="    depends_on:"$'\n'
        shared_services+="      openresty:"$'\n'
        shared_services+="        condition: service_started"$'\n'
        shared_services+="    networks:"$'\n'
        shared_services+="      - mempool_net"$'\n'
        shared_services+="${security_block}"
    fi

    # ==== Render the docker-compose template ====
    declare -A compose_vars=(
        [NETWORK_SERVICES]="${network_services}"
        [SHARED_SERVICES]="${shared_services}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/docker-compose.yml.tmpl" compose_vars)"

    write_file "${PROJECT_ROOT}/docker-compose.yml" "${output}"
}

# ==============================================================================
# UFW rules generator
# ==============================================================================
generate_ufw_rules() {
    local ufw_rules=""
    local tunnel_enabled
    tunnel_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED false)"

    local bind_ip
    bind_ip="$(get_config BIND_IP "127.0.0.1")"

    local web_port
    web_port="$(get_config WEB_PORT 80)"

    local tls_mode
    tls_mode="$(get_config TLS_MODE none)"

    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    local rpc_port=""
    if [[ "${rpc_enabled}" == "true" ]]; then
        rpc_port="$(get_config RPC_PORT 3000)"
    fi

    # --- Standard UFW rules (host-level) ---
    ufw_rules+="ufw allow ssh"$'\n'
    ufw_rules+=$'\n'

    if [[ "${tunnel_enabled}" == "true" ]]; then
        ufw_rules+="# Cloudflare Tunnel is enabled — web and RPC ports are NOT opened publicly."$'\n'
        ufw_rules+="# All external web/API traffic is routed through the Cloudflare Tunnel."$'\n'
        ufw_rules+=$'\n'
    else
        ufw_rules+="# Web traffic"$'\n'
        ufw_rules+="ufw allow ${web_port}/tcp"$'\n'
        if [[ "${tls_mode}" != "none" ]]; then
            ufw_rules+="ufw allow 443/tcp"$'\n'
        fi
        ufw_rules+=$'\n'

        if [[ "${rpc_enabled}" == "true" ]] && [[ -n "${rpc_port}" ]]; then
            ufw_rules+="# RPC Gateway"$'\n'
            ufw_rules+="ufw allow ${rpc_port}/tcp"$'\n'
            ufw_rules+=$'\n'
        fi
    fi

    # Bitcoin P2P ports (always needed, even with tunnel)
    ufw_rules+="# Bitcoin P2P ports"$'\n'
    local net
    for net in "${networks[@]}"; do
        get_default_ports "${net}"
        ufw_rules+="ufw allow ${BITCOIN_P2P_PORT}/tcp  # ${net}"$'\n'
    done

    ufw_rules+=$'\n'
    ufw_rules+="# Default policy"$'\n'
    ufw_rules+="ufw default deny incoming"$'\n'
    ufw_rules+="ufw default allow outgoing"$'\n'
    ufw_rules+="ufw --force enable"

    # --- ufw-docker rules (Docker container access) ---
    local docker_rules=""
    docker_rules+="# ufw-docker rules — allow traffic to Docker containers"$'\n'
    docker_rules+="# ufw-docker integrates UFW with Docker's iptables rules."$'\n'
    docker_rules+="# See: https://github.com/chaifeng/ufw-docker"$'\n'
    docker_rules+=$'\n'

    # Bitcoin P2P ports — open to all (needed for network connectivity)
    docker_rules+="# Bitcoin P2P — open to all"$'\n'
    for net in "${networks[@]}"; do
        get_default_ports "${net}"
        docker_rules+="ufw-docker allow bitcoind-${net} ${BITCOIN_P2P_PORT}"$'\n'
    done
    docker_rules+=$'\n'

    if [[ "${bind_ip}" == "127.0.0.1" ]]; then
        docker_rules+="# Web/RPC bound to localhost — no ufw-docker rules needed"$'\n'
        docker_rules+="# All external traffic flows through Cloudflare Tunnel"$'\n'
        docker_rules+=$'\n'
    else
        # Bind IP restricts access to the selected interface;
        # ufw-docker rules allow traffic through Docker's iptables
        docker_rules+="# Web"$'\n'
        docker_rules+="ufw-docker allow openresty ${web_port}"$'\n'
        if [[ "${tls_mode}" != "none" ]]; then
            docker_rules+="ufw-docker allow openresty 443"$'\n'
        fi
        docker_rules+=$'\n'

        if [[ "${rpc_enabled}" == "true" ]] && [[ -n "${rpc_port}" ]]; then
            docker_rules+="# RPC"$'\n'
            docker_rules+="ufw-docker allow openresty ${rpc_port}"$'\n'
            docker_rules+=$'\n'
        fi
    fi

    declare -A ufw_vars=(
        [UFW_RULES]="${ufw_rules}"
        [UFW_DOCKER_FIX]="${docker_rules}"
    )

    local output
    output="$(render_template "${TEMPLATE_DIR}/ufw-rules.tmpl" ufw_vars)"

    write_file "${CONFIG_DIR}/ufw-rules.sh" "${output}"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    log_header "Generating configuration"

    # Load node.conf
    load_config
    log_info "Loaded configuration from ${NODE_CONF}"

    # Validate required config keys
    local -a required_keys=(
        NETWORKS
        STORAGE_PATH
        BITCOIN_RPC_USER
        BITCOIN_RPC_PASS
        MARIADB_ROOT_PASS
        MARIADB_USER
        MARIADB_PASS
    )

    local missing=false
    local key
    for key in "${required_keys[@]}"; do
        if ! config_exists "${key}"; then
            log_error "Required config key missing: ${key}"
            missing=true
        fi
    done

    if ${missing}; then
        log_error "Aborting due to missing required configuration."
        exit 1
    fi

    # Validate networks
    mapfile -t networks < <(get_networks)
    if [[ ${#networks[@]} -eq 0 ]]; then
        log_error "No networks configured. Set NETWORKS in node.conf (e.g., NETWORKS=mainnet,signet)."
        exit 1
    fi

    local net
    for net in "${networks[@]}"; do
        if ! validate_network "${net}"; then
            log_error "Invalid network '${net}'. Supported: ${SUPPORTED_NETWORKS}"
            exit 1
        fi
    done

    log_info "Networks: ${networks[*]}"

    # Check for python3 (needed for rpcauth generation)
    if ! command -v python3 &>/dev/null; then
        log_warn "python3 not found. rpcauth generation will use fallback (rpcuser/rpcpassword)."
    fi

    # ---- Generate per-network configs ----
    for net in "${networks[@]}"; do
        log_info "Generating configs for ${net}..."
        generate_bitcoin_conf "${net}"
        generate_electrs_conf "${net}"
        generate_mempool_conf "${net}"
    done

    # ---- Generate shared configs ----
    log_info "Generating shared service configs..."
    generate_mariadb_init
    generate_nginx_conf
    generate_compose

    # ---- Generate conditional configs ----
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    if [[ "${rpc_enabled}" == "true" ]]; then
        log_info "RPC endpoint enabled — generating Lua script and API keys..."
        generate_lua_script
        generate_api_keys
    fi

    local tunnel_enabled
    tunnel_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED false)"
    if [[ "${tunnel_enabled}" == "true" ]]; then
        log_info "Cloudflare Tunnel enabled — generating tunnel config..."
        generate_cloudflared
    fi

    # ---- Generate firewall rules ----
    local ufw_enabled
    ufw_enabled="$(get_config UFW_ENABLED true)"
    if [[ "${ufw_enabled}" == "true" ]]; then
        log_info "Generating UFW firewall rules..."
        generate_ufw_rules
    else
        log_info "UFW disabled — skipping firewall rules generation."
    fi

    # ---- Summary ----
    log_header "Generation complete"
    log_success "Generated ${#GENERATED_FILES[@]} configuration files:"
    local f
    for f in "${GENERATED_FILES[@]}"; do
        log_info "  ${f}"
    done

    if ${DRY_RUN}; then
        log_warn "Dry-run mode was active — no files were actually written."
    else
        log_success "All configuration files generated successfully."
        log_info "Next step: docker compose up -d"
    fi
}

main "$@"
