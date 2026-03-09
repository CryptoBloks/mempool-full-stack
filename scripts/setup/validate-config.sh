#!/usr/bin/env bash
# ==============================================================================
# validate-config.sh - Validate node.conf and generated configuration files
#
# Ensures consistency and correctness before starting the Docker stack.
#
# Usage:
#   ./validate-config.sh              # validate everything
#   ./validate-config.sh --conf-only  # validate node.conf only
#   ./validate-config.sh --files-only # validate generated files only
#   ./validate-config.sh --quiet      # only show failures
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${SCRIPT_DIR}/../lib/config-utils.sh"
# shellcheck source=../lib/network-defaults.sh
source "${SCRIPT_DIR}/../lib/network-defaults.sh"

# ------------------------------------------------------------------------------
# Counters
# ------------------------------------------------------------------------------
ERRORS=0
WARNINGS=0
PASSED=0

# ------------------------------------------------------------------------------
# Options
# ------------------------------------------------------------------------------
OPT_CONF_ONLY=false
OPT_FILES_ONLY=false
OPT_QUIET=false

# ------------------------------------------------------------------------------
# Check-reporting helpers
# ------------------------------------------------------------------------------

# pass MESSAGE
#   Record a passing check and print it (unless --quiet).
pass() {
    (( PASSED++ )) || true
    if [[ "${OPT_QUIET}" != "true" ]]; then
        printf '  %s\xe2\x9c\x93%s %s\n' "${_CLR_GREEN}" "${_CLR_RESET}" "$*" >&2
    fi
}

# fail MESSAGE
#   Record a failing check and print it.
fail() {
    (( ERRORS++ )) || true
    printf '  %s\xe2\x9c\x97%s %s\n' "${_CLR_RED}" "${_CLR_RESET}" "$*" >&2
}

# warn_check MESSAGE
#   Record a warning and print it.
warn_check() {
    (( WARNINGS++ )) || true
    printf '  %s\xe2\x9a\xa0%s %s\n' "${_CLR_YELLOW}" "${_CLR_RESET}" "$*" >&2
}

# ------------------------------------------------------------------------------
# Utility: check that a file exists and is non-empty
# ------------------------------------------------------------------------------
check_file_exists() {
    local filepath="$1"
    local label="${2:-${filepath}}"

    if [[ ! -f "${filepath}" ]]; then
        fail "${label} does not exist (run generate-config.sh first)"
        return 1
    fi

    if [[ ! -s "${filepath}" ]]; then
        fail "${label} exists but is empty"
        return 1
    fi

    pass "${label} exists"
    return 0
}

# ------------------------------------------------------------------------------
# Utility: check that a file is valid JSON
# ------------------------------------------------------------------------------
check_valid_json() {
    local filepath="$1"
    local label="${2:-${filepath}}"

    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${filepath}" 2>/dev/null; then
        fail "${label} is not valid JSON"
        return 1
    fi

    pass "${label} is valid JSON"
    return 0
}

# ------------------------------------------------------------------------------
# Utility: check that a file contains a pattern
# ------------------------------------------------------------------------------
check_file_contains() {
    local filepath="$1"
    local pattern="$2"
    local label="$3"

    if grep -qE "${pattern}" "${filepath}" 2>/dev/null; then
        pass "${label}"
        return 0
    else
        fail "${label}"
        return 1
    fi
}

# ==============================================================================
# CATEGORY 1: node.conf validation
# ==============================================================================
validate_node_conf() {
    log_info "Validating node.conf..."

    # --- Check that node.conf exists ---
    if [[ ! -f "${NODE_CONF}" ]]; then
        fail "node.conf not found at ${NODE_CONF}"
        return
    fi

    # --- NETWORKS ---
    local networks_raw
    networks_raw="$(get_config NETWORKS)"
    if [[ -z "${networks_raw}" ]]; then
        fail "NETWORKS is not set"
    else
        # Validate each network
        local all_valid=true
        local -a network_list
        mapfile -t network_list < <(get_networks)

        if [[ "${#network_list[@]}" -eq 0 ]]; then
            fail "NETWORKS is set but contains no valid entries"
            all_valid=false
        else
            local net
            for net in "${network_list[@]}"; do
                if ! validate_network "${net}"; then
                    fail "Invalid network '${net}' in NETWORKS (expected: mainnet, signet, or testnet)"
                    all_valid=false
                fi
            done
            if [[ "${all_valid}" == "true" ]]; then
                pass "NETWORKS is set: ${networks_raw}"
            fi
        fi
    fi

    # --- STORAGE_PATH ---
    local storage_path
    storage_path="$(get_config STORAGE_PATH)"
    if [[ -z "${storage_path}" ]]; then
        fail "STORAGE_PATH is not set"
    elif ! validate_path "${storage_path}"; then
        fail "STORAGE_PATH is not an absolute path: ${storage_path}"
    else
        pass "STORAGE_PATH is valid: ${storage_path}"
    fi

    # --- Bitcoin RPC credentials ---
    local rpc_user rpc_pass
    rpc_user="$(get_config BITCOIN_RPC_USER)"
    rpc_pass="$(get_config BITCOIN_RPC_PASS)"
    if [[ -z "${rpc_user}" || -z "${rpc_pass}" ]]; then
        fail "Bitcoin RPC credentials are incomplete (BITCOIN_RPC_USER and BITCOIN_RPC_PASS required)"
    else
        pass "Bitcoin RPC credentials are set"
    fi

    # --- MariaDB credentials ---
    local db_root_pass db_user db_pass
    db_root_pass="$(get_config MARIADB_ROOT_PASS)"
    db_user="$(get_config MARIADB_USER)"
    db_pass="$(get_config MARIADB_PASS)"
    if [[ -z "${db_root_pass}" || -z "${db_user}" || -z "${db_pass}" ]]; then
        fail "MariaDB credentials are incomplete (MARIADB_ROOT_PASS, MARIADB_USER, MARIADB_PASS required)"
    else
        pass "MariaDB credentials are set"
    fi

    # --- TXINDEX / PRUNE cross-validation ---
    local txindex prune
    txindex="$(get_config TXINDEX "")"
    prune="$(get_config PRUNE "")"
    if [[ "${txindex}" == "true" ]] && [[ -n "${prune}" ]] && [[ "${prune}" =~ ^[0-9]+$ ]] && (( prune > 0 )); then
        fail "TXINDEX=true and PRUNE=${prune} are mutually exclusive"
    else
        pass "TXINDEX/PRUNE configuration is consistent"
    fi

    # --- RPC endpoint conditional checks ---
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "")"
    if [[ "${rpc_enabled}" == "true" ]]; then
        local rpc_api_key rpc_method_profile rpc_port gw_rpc_user gw_rpc_pass
        rpc_api_key="$(get_config RPC_API_KEY "")"
        rpc_method_profile="$(get_config RPC_METHOD_PROFILE "")"
        rpc_port="$(get_config RPC_PORT "")"
        gw_rpc_user="$(get_config GATEWAY_RPC_USER "")"
        gw_rpc_pass="$(get_config GATEWAY_RPC_PASS "")"

        if [[ -z "${rpc_api_key}" ]]; then
            fail "RPC_API_KEY must not be empty when RPC_ENDPOINT_ENABLED=true"
        else
            pass "RPC_API_KEY is set"
        fi

        case "${rpc_method_profile}" in
            read-only|standard|full)
                pass "RPC_METHOD_PROFILE is valid: ${rpc_method_profile}"
                ;;
            "")
                fail "RPC_METHOD_PROFILE must be set when RPC_ENDPOINT_ENABLED=true (expected: read-only, standard, full)"
                ;;
            *)
                fail "RPC_METHOD_PROFILE '${rpc_method_profile}' is invalid (expected: read-only, standard, full)"
                ;;
        esac

        if [[ -z "${rpc_port}" ]]; then
            fail "RPC_PORT must be set when RPC_ENDPOINT_ENABLED=true"
        elif ! validate_port "${rpc_port}"; then
            fail "RPC_PORT '${rpc_port}' is not a valid port (1-65535)"
        else
            pass "RPC_PORT is valid: ${rpc_port}"
        fi

        if [[ -z "${gw_rpc_user}" ]]; then
            fail "GATEWAY_RPC_USER must not be empty when RPC_ENDPOINT_ENABLED=true"
        else
            pass "GATEWAY_RPC_USER is set"
        fi

        if [[ -z "${gw_rpc_pass}" ]]; then
            fail "GATEWAY_RPC_PASS must not be empty when RPC_ENDPOINT_ENABLED=true"
        else
            pass "GATEWAY_RPC_PASS is set"
        fi

        # Warning: RPC endpoint works best with txindex
        if [[ "${txindex}" != "true" ]]; then
            warn_check "RPC_ENDPOINT_ENABLED=true but TXINDEX is not true (RPC endpoint works best with txindex)"
        fi
    fi

    # --- Port conflict check ---
    local web_port
    web_port="$(get_config WEB_PORT "")"
    if [[ -n "${web_port}" ]] && [[ -n "${rpc_port:-}" ]] && [[ "${web_port}" == "${rpc_port:-}" ]]; then
        fail "RPC_PORT conflicts with WEB_PORT (both ${web_port})"
    elif [[ -n "${web_port}" ]] && [[ -n "${rpc_port:-}" ]]; then
        pass "WEB_PORT (${web_port}) and RPC_PORT (${rpc_port}) do not conflict"
    fi

    # --- Cloudflare tunnel conditional checks ---
    local cf_enabled
    cf_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED "")"
    if [[ "${cf_enabled}" == "true" ]]; then
        local cf_token
        cf_token="$(get_config CLOUDFLARE_TUNNEL_TOKEN "")"
        if [[ -z "${cf_token}" ]]; then
            fail "CLOUDFLARE_TUNNEL_TOKEN must not be empty when CLOUDFLARE_TUNNEL_ENABLED=true"
        else
            pass "CLOUDFLARE_TUNNEL_TOKEN is set"
        fi
    fi

    # --- TLS / Letsencrypt conditional checks ---
    local tls_mode
    tls_mode="$(get_config TLS_MODE "")"
    if [[ "${tls_mode}" == "letsencrypt" ]]; then
        local domain_web le_email
        domain_web="$(get_config DOMAIN_WEB "")"
        le_email="$(get_config LETSENCRYPT_EMAIL "")"

        if [[ -z "${domain_web}" || "${domain_web}" == "_" ]]; then
            fail "DOMAIN_WEB must not be empty or '_' when TLS_MODE=letsencrypt"
        else
            pass "DOMAIN_WEB is set: ${domain_web}"
        fi

        if [[ -z "${le_email}" ]]; then
            fail "LETSENCRYPT_EMAIL must not be empty when TLS_MODE=letsencrypt"
        else
            pass "LETSENCRYPT_EMAIL is set"
        fi
    fi
}

# ==============================================================================
# CATEGORY 2: Generated files validation
# ==============================================================================
validate_generated_files() {
    log_info "Validating generated files..."

    local config_dir="${PROJECT_ROOT}/config"

    # --- Per-network files ---
    local -a network_list
    mapfile -t network_list < <(get_networks)

    if [[ "${#network_list[@]}" -eq 0 ]]; then
        fail "No networks configured; cannot validate per-network files"
        return
    fi

    local net
    for net in "${network_list[@]}"; do
        local net_dir="${config_dir}/${net}"

        # bitcoin.conf
        local bitcoin_conf="${net_dir}/bitcoin.conf"
        if check_file_exists "${bitcoin_conf}" "config/${net}/bitcoin.conf"; then
            # Content validation: server=1
            check_file_contains "${bitcoin_conf}" '^server=1' \
                "config/${net}/bitcoin.conf contains server=1"

            # Content validation: rpcallowip
            check_file_contains "${bitcoin_conf}" 'rpcallowip=' \
                "config/${net}/bitcoin.conf contains rpcallowip"

            # Content validation: network flag for non-mainnet
            if [[ "${net}" != "mainnet" ]]; then
                local expected_flag
                expected_flag="$(get_bitcoin_network_flag "${net}")"
                if [[ -n "${expected_flag}" ]]; then
                    check_file_contains "${bitcoin_conf}" "^${expected_flag}" \
                        "config/${net}/bitcoin.conf contains ${expected_flag}"
                fi
            fi
        fi

        # electrs.toml
        local electrs_toml="${net_dir}/electrs.toml"
        if check_file_exists "${electrs_toml}" "config/${net}/electrs.toml"; then
            # Content validation: daemon_rpc_addr points to correct container
            check_file_contains "${electrs_toml}" "daemon_rpc_addr.*bitcoind-${net}" \
                "config/${net}/electrs.toml daemon_rpc_addr references bitcoind-${net}"
        fi

        # mempool-config.json
        local mempool_json="${net_dir}/mempool-config.json"
        if check_file_exists "${mempool_json}" "config/${net}/mempool-config.json"; then
            if check_valid_json "${mempool_json}" "config/${net}/mempool-config.json"; then
                # Content validation: CORE_RPC.HOST matches bitcoind-{network}
                check_file_contains "${mempool_json}" "\"HOST\"[[:space:]]*:[[:space:]]*\"bitcoind-${net}\"" \
                    "config/${net}/mempool-config.json CORE_RPC.HOST matches bitcoind-${net}"

                # Content validation: DATABASE.DATABASE matches expected DB name
                get_chain_params "${net}"
                local expected_db="${CHAIN_DB_NAME}"
                check_file_contains "${mempool_json}" "\"DATABASE\"[[:space:]]*:[[:space:]]*\"${expected_db}\"" \
                    "config/${net}/mempool-config.json DATABASE.DATABASE matches ${expected_db}"
            fi
        fi
    done

    # --- Shared files ---
    check_file_exists "${config_dir}/mariadb/init/01-init.sql" "config/mariadb/init/01-init.sql"
    check_file_exists "${config_dir}/openresty/nginx.conf" "config/openresty/nginx.conf"
    check_file_exists "${PROJECT_ROOT}/docker-compose.yml" "docker-compose.yml"

    # docker-compose.yml content validation: service definitions
    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    if [[ -f "${compose_file}" ]] && [[ -s "${compose_file}" ]]; then
        for net in "${network_list[@]}"; do
            check_file_contains "${compose_file}" "bitcoind-${net}:" \
                "docker-compose.yml contains service definition for bitcoind-${net}"

            check_file_contains "${compose_file}" "electrs-${net}:" \
                "docker-compose.yml contains service definition for electrs-${net}"

            check_file_contains "${compose_file}" "mempool-api-${net}:" \
                "docker-compose.yml contains service definition for mempool-api-${net}"
        done

        # Shared services (check once, not per-network)
        check_file_contains "${compose_file}" "mempool-web:" \
            "docker-compose.yml contains service definition for mempool-web"
        check_file_contains "${compose_file}" "mariadb:" \
            "docker-compose.yml contains service definition for mariadb"
        check_file_contains "${compose_file}" "openresty:" \
            "docker-compose.yml contains service definition for openresty"
    fi

    # --- RPC endpoint files ---
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "")"
    if [[ "${rpc_enabled}" == "true" ]]; then
        local lua_file="${config_dir}/openresty/jsonrpc-access.lua"
        if [[ -f "${lua_file}" ]]; then
            pass "config/openresty/jsonrpc-access.lua exists"
        else
            fail "config/openresty/jsonrpc-access.lua does not exist (required for RPC endpoint)"
        fi

        local api_keys_file="${config_dir}/openresty/api-keys.json"
        if check_file_exists "${api_keys_file}" "config/openresty/api-keys.json"; then
            check_valid_json "${api_keys_file}" "config/openresty/api-keys.json"
        fi
    fi

    # --- Cloudflare tunnel files ---
    local cf_enabled
    cf_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED "")"
    if [[ "${cf_enabled}" == "true" ]]; then
        local cf_config="${config_dir}/cloudflared/config.yml"
        if [[ -f "${cf_config}" ]]; then
            pass "config/cloudflared/config.yml exists"
        else
            fail "config/cloudflared/config.yml does not exist (required for Cloudflare tunnel)"
        fi
    fi
}

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --conf-only)
            OPT_CONF_ONLY=true
            shift
            ;;
        --files-only)
            OPT_FILES_ONLY=true
            shift
            ;;
        --quiet)
            OPT_QUIET=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: validate-config.sh [OPTIONS]

Validate node.conf and generated configuration files.

Options:
  --conf-only   Only validate node.conf, skip generated files check
  --files-only  Only validate generated files, skip node.conf validation
  --quiet       Only show failures and warnings
  -h, --help    Show this help message

Exit codes:
  0  All checks passed (or only warnings)
  1  One or more errors found
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

# Mutually exclusive options
if [[ "${OPT_CONF_ONLY}" == "true" ]] && [[ "${OPT_FILES_ONLY}" == "true" ]]; then
    log_error "--conf-only and --files-only are mutually exclusive"
    exit 1
fi

# ==============================================================================
# Main
# ==============================================================================
load_config

if [[ "${OPT_FILES_ONLY}" != "true" ]]; then
    validate_node_conf
fi

if [[ "${OPT_CONF_ONLY}" != "true" ]]; then
    validate_generated_files
fi

# Summary
echo "" >&2
echo "Validation complete: ${PASSED} passed, ${ERRORS} failed, ${WARNINGS} warnings" >&2

if (( ERRORS > 0 )); then
    exit 1
else
    exit 0
fi
