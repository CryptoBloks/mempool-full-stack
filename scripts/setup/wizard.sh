#!/usr/bin/env bash
# ==============================================================================
# wizard.sh — Interactive setup wizard for mempool.space full-stack-docker
#
# Creates (or updates) node.conf through 11 guided configuration sections,
# then runs generate-config.sh to render all service configs and compose file.
#
# Usage:
#   ./scripts/setup/wizard.sh                  # interactive mode
#   ./scripts/setup/wizard.sh --non-interactive # use existing node.conf, skip prompts
#   ./scripts/setup/wizard.sh --help
#
# Re-running with an existing node.conf pre-fills previous values as defaults.
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Source shared libraries
# ==============================================================================
_WIZ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_WIZ_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_WIZ_DIR}/../lib/config-utils.sh"
# shellcheck source=../lib/network-defaults.sh
source "${_WIZ_DIR}/../lib/network-defaults.sh"

# ==============================================================================
# Globals
# ==============================================================================
NON_INTERACTIVE=false
SKIP_GENERATE=false

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --skip-generate)
            SKIP_GENERATE=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: wizard.sh [OPTIONS]

Interactive setup wizard for mempool.space full-stack-docker.
Creates node.conf and generates all service configuration files.

Options:
  --non-interactive   Skip prompts, use existing node.conf values (or defaults)
  --skip-generate     Do not run generate-config.sh after wizard completes
  -h, --help          Show this help message

Re-running with an existing node.conf pre-fills previous values as defaults.
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

# ==============================================================================
# Helper: set a config value, using existing value or default in non-interactive
# ==============================================================================
# wiz_set KEY VALUE
#   Convenience wrapper: sets config and logs it.
wiz_set() {
    set_config "$1" "$2"
}

# wiz_default KEY DEFAULT
#   Returns the existing config value for KEY, or DEFAULT if not set.
wiz_default() {
    local key="$1"
    local default="$2"
    if config_exists "${key}"; then
        get_config "${key}"
    else
        printf '%s' "${default}"
    fi
}

# ==============================================================================
# Banner
# ==============================================================================
show_banner() {
    printf '\n' >&2
    printf '%s' "${_CLR_BOLD}${_CLR_CYAN}" >&2
    cat >&2 <<'BANNER'
  __  __                                _
 |  \/  | ___ _ __ ___  _ __   ___   ___ | |
 | |\/| |/ _ \ '_ ` _ \| '_ \ / _ \ / _ \| |
 | |  | |  __/ | | | | | |_) | (_) | (_) | |
 |_|  |_|\___|_| |_| |_| .__/ \___/ \___/|_|
                        |_|
  Full Stack Docker — Setup Wizard
BANNER
    printf '%s\n' "${_CLR_RESET}" >&2
}

# ==============================================================================
# Section 1: Network Selection
# ==============================================================================
section_networks() {
    log_header "1/11 — Network Selection"

    local existing
    existing="$(wiz_default NETWORKS "mainnet,signet")"

    if ${NON_INTERACTIVE}; then
        log_info "Networks: ${existing}"
        wiz_set NETWORKS "${existing}"
        return
    fi

    log_info "Select which Bitcoin networks to deploy."
    log_info "Each network runs its own bitcoind, electrs, and mempool-api containers."
    printf '\n' >&2

    # Parse existing selections into an array for defaults
    local -A selected=()
    IFS=',' read -ra prev_nets <<< "${existing}"
    for n in "${prev_nets[@]}"; do
        n="${n#"${n%%[![:space:]]*}"}"
        n="${n%"${n##*[![:space:]]}"}"
        selected["${n}"]=1
    done

    local -a all_nets=(mainnet signet testnet)
    local -a descriptions=(
        "Full Bitcoin mainnet (~600GB+ storage)"
        "Bitcoin Signet test network (~5GB)"
        "Bitcoin Testnet3 (~30GB)"
    )

    # Display toggle menu
    local done_selecting=false
    while ! ${done_selecting}; do
        printf '\n' >&2
        local i
        for i in "${!all_nets[@]}"; do
            local net="${all_nets[$i]}"
            local mark="  "
            if [[ -n "${selected[${net}]:-}" ]]; then
                mark="${_CLR_GREEN}[x]${_CLR_RESET}"
            else
                mark="[ ]"
            fi
            printf '  %s %s%d%s) %-10s %s\n' "${mark}" "${_CLR_BOLD}" "$(( i + 1 ))" "${_CLR_RESET}" "${net}" "${descriptions[$i]}" >&2
        done

        printf '\nToggle by number (1-3), press Enter when done: ' >&2
        local input
        read -r input

        if [[ -z "${input}" ]]; then
            done_selecting=true
        elif [[ "${input}" =~ ^[123]$ ]]; then
            local toggled="${all_nets[$(( input - 1 ))]}"
            if [[ -n "${selected[${toggled}]:-}" ]]; then
                unset 'selected['"${toggled}"']'
            else
                selected["${toggled}"]=1
            fi
        else
            log_warn "Enter 1, 2, or 3 to toggle, or press Enter to confirm."
        fi
    done

    # Build comma-separated list
    local result=""
    for net in mainnet signet testnet; do
        if [[ -n "${selected[${net}]:-}" ]]; then
            [[ -n "${result}" ]] && result+=","
            result+="${net}"
        fi
    done

    if [[ -z "${result}" ]]; then
        log_error "At least one network must be selected."
        section_networks  # recurse
        return
    fi

    wiz_set NETWORKS "${result}"
    log_success "Selected: ${result}"
}

# ==============================================================================
# Section 2: Bitcoin Core Source
# ==============================================================================
section_bitcoin_source() {
    log_header "2/11 — Bitcoin Core Source"

    # Only docker-image mode is currently supported.
    # Build-from-source and external Bitcoin Core will be added in a future release.
    wiz_set BITCOIN_MODE "docker-image"
    log_info "Bitcoin Core mode: docker-image (official Docker images)"
}

# ==============================================================================
# Section 3: Application Versions
# ==============================================================================
section_versions() {
    log_header "3/11 — Application Versions"

    get_default_versions

    if ${NON_INTERACTIVE}; then
        wiz_set BITCOIN_VERSION "$(wiz_default BITCOIN_VERSION "${RECOMMENDED_BITCOIN_VERSION}")"
        wiz_set MEMPOOL_VERSION "$(wiz_default MEMPOOL_VERSION "${RECOMMENDED_MEMPOOL_VERSION}")"
        wiz_set ELECTRS_VERSION "$(wiz_default ELECTRS_VERSION "${RECOMMENDED_ELECTRS_VERSION}")"
        wiz_set MARIADB_VERSION "$(wiz_default MARIADB_VERSION "${RECOMMENDED_MARIADB_VERSION}")"
        wiz_set OPENRESTY_VERSION "$(wiz_default OPENRESTY_VERSION "${RECOMMENDED_OPENRESTY_VERSION}")"
        log_info "Using default/existing versions."
        return
    fi

    # Try to fetch latest Bitcoin Core version from GitHub
    local -a bitcoin_versions=("${SUPPORTED_BITCOIN_VERSIONS[@]}")
    if command -v curl &>/dev/null; then
        log_info "Checking GitHub for latest Bitcoin Core releases..."
        local gh_versions
        gh_versions="$(curl -sf --max-time 10 \
            'https://api.github.com/repos/bitcoin/bitcoin/releases?per_page=5' 2>/dev/null \
            | python3 -c "
import json,sys
try:
    releases = json.load(sys.stdin)
    for r in releases:
        tag = r.get('tag_name','')
        if tag.startswith('v') and not r.get('prerelease'):
            print(tag[1:])
except: pass
" 2>/dev/null || true)"

        if [[ -n "${gh_versions}" ]]; then
            mapfile -t bitcoin_versions <<< "${gh_versions}"
            log_success "Found releases: ${bitcoin_versions[*]}"
        else
            log_warn "Could not fetch from GitHub; using built-in version list."
        fi
    fi

    # Bitcoin Core version
    local btc_default
    btc_default="$(wiz_default BITCOIN_VERSION "${RECOMMENDED_BITCOIN_VERSION}")"
    local btc_default_idx=1
    for i in "${!bitcoin_versions[@]}"; do
        if [[ "${bitcoin_versions[$i]}" == "${btc_default}" ]]; then
            btc_default_idx=$(( i + 1 ))
            break
        fi
    done
    local btc_choice
    btc_choice="$(ask_choice "Select Bitcoin Core version:" bitcoin_versions "${btc_default_idx}")"
    wiz_set BITCOIN_VERSION "${btc_choice}"

    # Mempool version
    local -a mempool_versions=("${SUPPORTED_MEMPOOL_VERSIONS[@]}")
    # Try fetching from GitHub
    if command -v curl &>/dev/null; then
        local gh_mempool
        gh_mempool="$(curl -sf --max-time 10 \
            'https://api.github.com/repos/mempool/mempool/releases?per_page=5' 2>/dev/null \
            | python3 -c "
import json,sys
try:
    releases = json.load(sys.stdin)
    for r in releases:
        tag = r.get('tag_name','')
        if tag.startswith('v') and not r.get('prerelease'):
            print(tag[1:])
except: pass
" 2>/dev/null || true)"

        if [[ -n "${gh_mempool}" ]]; then
            mapfile -t mempool_versions <<< "${gh_mempool}"
        fi
    fi

    local mem_default
    mem_default="$(wiz_default MEMPOOL_VERSION "${RECOMMENDED_MEMPOOL_VERSION}")"
    local mem_default_idx=1
    for i in "${!mempool_versions[@]}"; do
        if [[ "${mempool_versions[$i]}" == "${mem_default}" ]]; then
            mem_default_idx=$(( i + 1 ))
            break
        fi
    done
    local mem_choice
    mem_choice="$(ask_choice "Select Mempool version:" mempool_versions "${mem_default_idx}")"
    wiz_set MEMPOOL_VERSION "${mem_choice}"

    # Electrs / MariaDB / OpenResty — use recommended defaults, allow override
    local electrs_v mariadb_v openresty_v
    electrs_v="$(ask_input "Electrs version" "$(wiz_default ELECTRS_VERSION "${RECOMMENDED_ELECTRS_VERSION}")")"
    mariadb_v="$(ask_input "MariaDB version" "$(wiz_default MARIADB_VERSION "${RECOMMENDED_MARIADB_VERSION}")")"
    openresty_v="$(ask_input "OpenResty version" "$(wiz_default OPENRESTY_VERSION "${RECOMMENDED_OPENRESTY_VERSION}")")"

    wiz_set ELECTRS_VERSION "${electrs_v}"
    wiz_set MARIADB_VERSION "${mariadb_v}"
    wiz_set OPENRESTY_VERSION "${openresty_v}"

    log_success "Versions configured."
}

# ==============================================================================
# Section 4: Storage Configuration
# ==============================================================================
section_storage() {
    log_header "4/11 — Storage Configuration"

    local default_path
    default_path="$(wiz_default STORAGE_PATH "/data/mempool")"

    if ${NON_INTERACTIVE}; then
        wiz_set STORAGE_PATH "${default_path}"
        wiz_set BTRFS_ENABLED "$(wiz_default BTRFS_ENABLED "false")"
        log_info "Storage path: ${default_path}"
        return
    fi

    local storage_path
    while true; do
        storage_path="$(ask_input "Base storage path" "${default_path}")"
        if validate_path "${storage_path}"; then
            break
        fi
        log_error "Must be an absolute path (starting with /)."
    done

    wiz_set STORAGE_PATH "${storage_path}"

    # Check if path exists
    printf '\nChecking storage path...\n' >&2
    if [[ -d "${storage_path}" ]]; then
        log_success "Path exists"
    else
        log_warn "Path does not exist. It will be created during deployment."
    fi

    # Check BTRFS
    local btrfs_enabled="false"
    if [[ -d "${storage_path}" ]]; then
        local fstype
        fstype="$(df -T "${storage_path}" 2>/dev/null | awk 'NR==2 {print $2}')" || true
        if [[ "${fstype}" == "btrfs" ]]; then
            log_success "BTRFS filesystem detected (recommended for snapshots)"
            if ask_yes_no "Enable BTRFS snapshot support?" "y"; then
                btrfs_enabled="true"
            fi
        else
            log_info "Filesystem type: ${fstype:-unknown} (BTRFS recommended for snapshots)"
        fi

        # Check available space
        local avail_gb
        avail_gb="$(df -BG "${storage_path}" | awk 'NR==2 { gsub(/G/, "", $4); print $4 }')" || true
        if [[ -n "${avail_gb}" ]]; then
            log_info "Available space: ${avail_gb}GB"
        fi
    fi

    wiz_set BTRFS_ENABLED "${btrfs_enabled}"
    log_success "Storage configured: ${storage_path}"
}

# ==============================================================================
# Section 5: Bitcoin Core Options
# ==============================================================================
section_bitcoin_options() {
    log_header "5/11 — Bitcoin Core Options"

    local default_txindex
    default_txindex="$(wiz_default TXINDEX "true")"
    local default_prune
    default_prune="$(wiz_default PRUNE "0")"

    if ${NON_INTERACTIVE}; then
        wiz_set TXINDEX "${default_txindex}"
        wiz_set PRUNE "${default_prune}"
        wiz_set DBCACHE "$(wiz_default DBCACHE "2048")"
        wiz_set MAXMEMPOOL "$(wiz_default MAXMEMPOOL "300")"
        wiz_set MAXCONNECTIONS "$(wiz_default MAXCONNECTIONS "40")"
        log_info "Bitcoin Core options: txindex=${default_txindex}, prune=${default_prune}"
        return
    fi

    local txindex="true"
    local prune="0"

    log_info "Transaction index (txindex) enables full transaction lookups."
    log_info "Required for the RPC web endpoint. Adds ~30GB to storage."
    if ask_yes_no "Enable transaction index (txindex)?" "y"; then
        txindex="true"
        prune="0"
        log_info "txindex enabled — pruning is disabled (they are mutually exclusive)."
    else
        txindex="false"
        log_info "txindex disabled."

        if ask_yes_no "Enable pruning? (reduces storage but limits functionality)" "n"; then
            local prune_size
            prune_size="$(ask_input "Prune target in MB (minimum 550)" "$(wiz_default PRUNE "1000")")"
            if [[ "${prune_size}" =~ ^[0-9]+$ ]] && (( prune_size >= 550 )); then
                prune="${prune_size}"
            else
                log_warn "Invalid prune size, using 1000 MB."
                prune="1000"
            fi
        fi
    fi

    wiz_set TXINDEX "${txindex}"
    wiz_set PRUNE "${prune}"

    # Performance tuning
    local dbcache maxmempool maxconnections
    dbcache="$(ask_input "Bitcoin Core dbcache (MB)" "$(wiz_default DBCACHE "2048")")"
    maxmempool="$(ask_input "Max mempool size (MB)" "$(wiz_default MAXMEMPOOL "300")")"
    maxconnections="$(ask_input "Max connections" "$(wiz_default MAXCONNECTIONS "40")")"

    wiz_set DBCACHE "${dbcache}"
    wiz_set MAXMEMPOOL "${maxmempool}"
    wiz_set MAXCONNECTIONS "${maxconnections}"

    log_success "Bitcoin Core options configured."
}

# ==============================================================================
# Section 6: RPC Web Endpoint
# ==============================================================================
section_rpc_endpoint() {
    log_header "6/11 — RPC Web Endpoint"

    local default_enabled
    default_enabled="$(wiz_default RPC_ENDPOINT_ENABLED "false")"

    if ${NON_INTERACTIVE}; then
        wiz_set RPC_ENDPOINT_ENABLED "${default_enabled}"
        if [[ "${default_enabled}" == "true" ]]; then
            wiz_set RPC_AUTH_MODE "$(wiz_default RPC_AUTH_MODE "api-key")"
            wiz_set RPC_METHOD_PROFILE "$(wiz_default RPC_METHOD_PROFILE "read-only")"
            wiz_set RPC_RATE_LIMIT "$(wiz_default RPC_RATE_LIMIT "60")"
            wiz_set RPC_PORT "$(wiz_default RPC_PORT "3000")"
            # Ensure API key and gateway creds exist
            if ! config_exists RPC_API_KEY; then
                wiz_set RPC_API_KEY "mk_live_$(generate_password 32)"
            fi
            if ! config_exists GATEWAY_RPC_USER; then
                wiz_set GATEWAY_RPC_USER "gateway"
            fi
            if ! config_exists GATEWAY_RPC_PASS; then
                wiz_set GATEWAY_RPC_PASS "$(generate_password 32)"
            fi
        fi
        log_info "RPC endpoint: ${default_enabled}"
        return
    fi

    log_info "The RPC web endpoint exposes Bitcoin Core RPC over HTTPS"
    log_info "with API key authentication (Alchemy/QuickNode style)."

    local rpc_default_yn="n"
    [[ "${default_enabled}" == "true" ]] && rpc_default_yn="y"

    if ask_yes_no "Enable Bitcoin RPC web endpoint?" "${rpc_default_yn}"; then
        wiz_set RPC_ENDPOINT_ENABLED "true"

        # Check txindex
        local txindex
        txindex="$(get_config TXINDEX "false")"
        if [[ "${txindex}" != "true" ]]; then
            log_warn "RPC endpoint works best with txindex=true (currently ${txindex})."
            log_warn "Some RPC methods may not work without txindex."
        fi

        # Only api-key auth mode is currently implemented
        wiz_set RPC_AUTH_MODE "api-key"
        log_info "Auth mode: api-key (path-based and X-API-Key header)"

        # API key generation
        local existing_key
        existing_key="$(wiz_default RPC_API_KEY "")"
        if [[ -n "${existing_key}" ]]; then
            log_info "Existing API key: ${existing_key:0:12}..."
            if ! ask_yes_no "Keep existing API key?" "y"; then
                existing_key=""
            fi
        fi

        if [[ -z "${existing_key}" ]]; then
            if ask_yes_no "Generate a new API key?" "y"; then
                existing_key="mk_live_$(generate_password 32)"
                log_success "Generated: ${existing_key}"
            else
                existing_key="$(ask_input "Enter API key" "")"
            fi
        fi
        wiz_set RPC_API_KEY "${existing_key}"

        # Method profile
        local -a profiles=("read-only" "standard" "full")
        local prof_default=1
        local existing_prof
        existing_prof="$(wiz_default RPC_METHOD_PROFILE "read-only")"
        case "${existing_prof}" in
            standard) prof_default=2 ;;
            full) prof_default=3 ;;
        esac

        log_info ""
        log_info "Method profiles:"
        log_info "  read-only  — Safe read methods only (recommended)"
        log_info "  standard   — Read + transaction broadcast"
        log_info "  full       — All methods (dangerous)"
        local prof_choice
        prof_choice="$(ask_choice "RPC method profile:" profiles "${prof_default}")"
        wiz_set RPC_METHOD_PROFILE "${prof_choice}"

        # Rate limiting
        local rate_limit
        rate_limit="$(ask_input "Rate limit (requests per minute per key)" "$(wiz_default RPC_RATE_LIMIT "60")")"
        wiz_set RPC_RATE_LIMIT "${rate_limit}"

        # Port
        local rpc_port
        rpc_port="$(ask_input "RPC endpoint port" "$(wiz_default RPC_PORT "3000")")"
        wiz_set RPC_PORT "${rpc_port}"

        # Gateway RPC credentials (for defense-in-depth on bitcoind)
        if ! config_exists GATEWAY_RPC_USER; then
            wiz_set GATEWAY_RPC_USER "gateway"
        fi
        if ! config_exists GATEWAY_RPC_PASS; then
            wiz_set GATEWAY_RPC_PASS "$(generate_password 32)"
        fi

        log_success "RPC endpoint enabled: api-key auth, ${prof_choice} profile, port ${rpc_port}"
    else
        wiz_set RPC_ENDPOINT_ENABLED "false"
        log_info "RPC endpoint disabled."
    fi
}

# ==============================================================================
# Section 7: Port Configuration
# ==============================================================================
section_ports() {
    log_header "7/11 — Port Configuration"

    local default_web
    default_web="$(wiz_default WEB_PORT "80")"

    if ${NON_INTERACTIVE}; then
        wiz_set WEB_PORT "${default_web}"
        log_info "Web port: ${default_web}"
        return
    fi

    local web_port
    while true; do
        web_port="$(ask_input "Mempool web interface port" "${default_web}")"
        if validate_port "${web_port}"; then
            break
        fi
        log_error "Invalid port. Must be 1-65535."
    done
    wiz_set WEB_PORT "${web_port}"

    # Show summary of all ports
    printf '\n' >&2
    log_info "Port summary:"
    log_info "  Web interface:  ${web_port}"

    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
    if [[ "${rpc_enabled}" == "true" ]]; then
        log_info "  RPC endpoint:   $(get_config RPC_PORT 3000)"
    fi

    mapfile -t nets < <(get_networks)
    for net in "${nets[@]}"; do
        get_default_ports "${net}"
        log_info "  Bitcoin P2P (${net}): ${BITCOIN_P2P_PORT}"
    done

    # Port conflict check
    local -a used_ports=("${web_port}")
    local conflict=false
    if [[ "${rpc_enabled}" == "true" ]]; then
        local rpc_port
        rpc_port="$(get_config RPC_PORT 3000)"
        if [[ "${rpc_port}" == "${web_port}" ]]; then
            log_error "RPC port (${rpc_port}) conflicts with web port (${web_port})!"
            conflict=true
        fi
        used_ports+=("${rpc_port}")
    fi

    if ! ${conflict}; then
        log_success "No port conflicts detected."
    fi
}

# ==============================================================================
# Section 8: SSL/TLS
# ==============================================================================
section_tls() {
    log_header "8/11 — SSL/TLS Configuration"

    local default_mode
    default_mode="$(wiz_default TLS_MODE "none")"

    if ${NON_INTERACTIVE}; then
        wiz_set TLS_MODE "${default_mode}"
        wiz_set DOMAIN_WEB "$(wiz_default DOMAIN_WEB "_")"
        log_info "TLS mode: ${default_mode}"
        return
    fi

    local -a tls_options=(
        "none          No SSL (HTTP only)"
        "self-signed   Generate self-signed certificates"
        "letsencrypt   Let's Encrypt (requires domain + port 80/443)"
    )

    local tls_default_idx=1
    case "${default_mode}" in
        self-signed) tls_default_idx=2 ;;
        letsencrypt) tls_default_idx=3 ;;
    esac

    local tls_choice
    tls_choice="$(ask_choice "SSL/TLS configuration:" tls_options "${tls_default_idx}")"
    local tls_mode="${tls_choice%% *}"

    wiz_set TLS_MODE "${tls_mode}"

    case "${tls_mode}" in
        letsencrypt)
            local domain email
            domain="$(ask_input "Domain name for web interface" "$(wiz_default DOMAIN_WEB "")")"
            email="$(ask_input "Let's Encrypt notification email" "$(wiz_default LETSENCRYPT_EMAIL "")")"
            wiz_set DOMAIN_WEB "${domain}"
            wiz_set LETSENCRYPT_EMAIL "${email}"

            local rpc_enabled
            rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
            if [[ "${rpc_enabled}" == "true" ]]; then
                local rpc_domain
                rpc_domain="$(ask_input "Domain name for RPC endpoint (or same as web)" "$(wiz_default DOMAIN_RPC "${domain}")")"
                wiz_set DOMAIN_RPC "${rpc_domain}"
            fi
            ;;
        self-signed)
            local domain
            domain="$(ask_input "Server hostname (for certificate CN)" "$(wiz_default DOMAIN_WEB "$(hostname -f 2>/dev/null || echo localhost)")")"
            wiz_set DOMAIN_WEB "${domain}"
            ;;
        none)
            wiz_set DOMAIN_WEB "_"
            ;;
    esac

    log_success "TLS mode: ${tls_mode}"
}

# ==============================================================================
# Section 9: Cloudflare Tunnel
# ==============================================================================
section_cloudflare() {
    log_header "9/11 — Cloudflare Tunnel"

    local default_enabled
    default_enabled="$(wiz_default CLOUDFLARE_TUNNEL_ENABLED "false")"

    if ${NON_INTERACTIVE}; then
        wiz_set CLOUDFLARE_TUNNEL_ENABLED "${default_enabled}"
        log_info "Cloudflare Tunnel: ${default_enabled}"
        return
    fi

    log_info "Cloudflare Tunnel provides remote access via Cloudflare Zero Trust"
    log_info "without opening firewall ports. Requires a Cloudflare account."

    local cf_default_yn="n"
    [[ "${default_enabled}" == "true" ]] && cf_default_yn="y"

    if ask_yes_no "Enable Cloudflare Tunnel for remote access?" "${cf_default_yn}"; then
        wiz_set CLOUDFLARE_TUNNEL_ENABLED "true"

        local token
        token="$(ask_secret "Cloudflare Tunnel token (from Zero Trust dashboard)")"
        wiz_set CLOUDFLARE_TUNNEL_TOKEN "${token}"

        if ask_yes_no "Expose Mempool web via tunnel?" "y"; then
            local cf_web_host
            cf_web_host="$(ask_input "Tunnel hostname for web" "$(wiz_default CF_HOSTNAME_WEB "mempool.yourdomain.com")")"
            wiz_set CF_HOSTNAME_WEB "${cf_web_host}"
        fi

        local rpc_enabled
        rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
        if [[ "${rpc_enabled}" == "true" ]]; then
            if ask_yes_no "Expose RPC endpoint via tunnel?" "n"; then
                local cf_rpc_host
                cf_rpc_host="$(ask_input "Tunnel hostname for RPC" "$(wiz_default CF_HOSTNAME_RPC "rpc.yourdomain.com")")"
                wiz_set CF_HOSTNAME_RPC "${cf_rpc_host}"
            fi
        fi

        log_success "Cloudflare Tunnel enabled."
    else
        wiz_set CLOUDFLARE_TUNNEL_ENABLED "false"
        log_info "Cloudflare Tunnel disabled."
    fi
}

# ==============================================================================
# Section 10: Firewall
# ==============================================================================
section_firewall() {
    log_header "10/11 — Firewall Configuration"

    local default_enabled
    default_enabled="$(wiz_default UFW_ENABLED "true")"

    if ${NON_INTERACTIVE}; then
        wiz_set UFW_ENABLED "${default_enabled}"
        log_info "UFW firewall: ${default_enabled}"
        return
    fi

    if ! command -v ufw &>/dev/null; then
        log_warn "UFW is not installed. Skipping firewall configuration."
        log_info "Install with: sudo apt install ufw"
        wiz_set UFW_ENABLED "false"
        return
    fi

    local ufw_default_yn="y"
    [[ "${default_enabled}" == "false" ]] && ufw_default_yn="n"

    if ask_yes_no "Configure UFW firewall?" "${ufw_default_yn}"; then
        wiz_set UFW_ENABLED "true"

        # Show what will be allowed
        printf '\n' >&2
        log_info "The following ports will be configured:"
        log_info "  ${_CLR_GREEN}ALLOW${_CLR_RESET}  22/tcp     SSH"

        local web_port
        web_port="$(get_config WEB_PORT 80)"
        local cf_enabled
        cf_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED "false")"

        if [[ "${cf_enabled}" == "true" ]]; then
            log_info "  ${_CLR_YELLOW}SKIP${_CLR_RESET}   ${web_port}/tcp    Web (handled by Cloudflare Tunnel)"
        else
            log_info "  ${_CLR_GREEN}ALLOW${_CLR_RESET}  ${web_port}/tcp    Mempool Web"
        fi

        mapfile -t nets < <(get_networks)
        for net in "${nets[@]}"; do
            get_default_ports "${net}"
            log_info "  ${_CLR_GREEN}ALLOW${_CLR_RESET}  ${BITCOIN_P2P_PORT}/tcp  Bitcoin P2P (${net})"
        done

        local rpc_enabled
        rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
        if [[ "${rpc_enabled}" == "true" ]]; then
            local rpc_port
            rpc_port="$(get_config RPC_PORT 3000)"
            if [[ "${cf_enabled}" == "true" ]]; then
                log_info "  ${_CLR_YELLOW}SKIP${_CLR_RESET}   ${rpc_port}/tcp   RPC (handled by Cloudflare Tunnel)"
            else
                log_info "  ${_CLR_GREEN}ALLOW${_CLR_RESET}  ${rpc_port}/tcp   RPC Endpoint"
            fi
        fi

        log_info "  ${_CLR_RED}DENY${_CLR_RESET}   *          Everything else (incoming)"

        printf '\n' >&2
        log_success "Firewall rules will be generated by generate-config.sh"
    else
        wiz_set UFW_ENABLED "false"
        log_info "Firewall configuration skipped."
    fi
}

# ==============================================================================
# Section 11: Credentials
# ==============================================================================
section_credentials() {
    log_header "11/11 — Credential Generation"

    if ${NON_INTERACTIVE}; then
        # Ensure all required credentials exist; generate if missing
        if ! config_exists BITCOIN_RPC_USER; then
            local suffix
            suffix="$(generate_password 6)"
            wiz_set BITCOIN_RPC_USER "mempool_${suffix}"
        fi
        if ! config_exists BITCOIN_RPC_PASS; then
            wiz_set BITCOIN_RPC_PASS "$(generate_password 32)"
        fi
        if ! config_exists MARIADB_ROOT_PASS; then
            wiz_set MARIADB_ROOT_PASS "$(generate_password 32)"
        fi
        if ! config_exists MARIADB_USER; then
            wiz_set MARIADB_USER "mempool"
        fi
        if ! config_exists MARIADB_PASS; then
            wiz_set MARIADB_PASS "$(generate_password 32)"
        fi
        log_info "Credentials verified/generated."
        return
    fi

    log_info "Auto-generating secure credentials for all services."
    log_info "Existing credentials will be preserved unless you choose to regenerate."
    printf '\n' >&2

    # Bitcoin RPC
    local rpc_user rpc_pass
    if config_exists BITCOIN_RPC_USER && config_exists BITCOIN_RPC_PASS; then
        rpc_user="$(get_config BITCOIN_RPC_USER)"
        rpc_pass="$(get_config BITCOIN_RPC_PASS)"
        log_info "Bitcoin RPC user: ${rpc_user} (existing)"
        if ask_yes_no "Regenerate Bitcoin RPC credentials?" "n"; then
            local suffix
            suffix="$(generate_password 6)"
            rpc_user="mempool_${suffix}"
            rpc_pass="$(generate_password 32)"
        fi
    else
        local suffix
        suffix="$(generate_password 6)"
        rpc_user="mempool_${suffix}"
        rpc_pass="$(generate_password 32)"
    fi
    wiz_set BITCOIN_RPC_USER "${rpc_user}"
    wiz_set BITCOIN_RPC_PASS "${rpc_pass}"
    log_success "Bitcoin RPC: user=${rpc_user}"

    # MariaDB
    local db_root_pass db_user db_pass
    if config_exists MARIADB_ROOT_PASS; then
        db_root_pass="$(get_config MARIADB_ROOT_PASS)"
        log_info "MariaDB root password: (existing, preserved)"
        if ask_yes_no "Regenerate MariaDB root password?" "n"; then
            db_root_pass="$(generate_password 32)"
        fi
    else
        db_root_pass="$(generate_password 32)"
    fi
    wiz_set MARIADB_ROOT_PASS "${db_root_pass}"

    db_user="$(wiz_default MARIADB_USER "mempool")"
    if config_exists MARIADB_PASS; then
        db_pass="$(get_config MARIADB_PASS)"
        log_info "MariaDB app user: ${db_user} (existing)"
    else
        db_pass="$(generate_password 32)"
    fi
    wiz_set MARIADB_USER "${db_user}"
    wiz_set MARIADB_PASS "${db_pass}"
    log_success "MariaDB: user=${db_user}"

    # RPC Gateway credentials (if enabled)
    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
    if [[ "${rpc_enabled}" == "true" ]]; then
        if ! config_exists GATEWAY_RPC_USER; then
            wiz_set GATEWAY_RPC_USER "gateway"
        fi
        if ! config_exists GATEWAY_RPC_PASS; then
            wiz_set GATEWAY_RPC_PASS "$(generate_password 32)"
        fi
        log_success "RPC Gateway: user=$(get_config GATEWAY_RPC_USER)"
        log_success "RPC API Key: $(get_config RPC_API_KEY | head -c 16)..."
    fi

    printf '\n' >&2
    log_success "All credentials configured."
    log_warn "Credentials are stored in node.conf — keep this file secure!"
}

# ==============================================================================
# Summary
# ==============================================================================
show_summary() {
    log_header "Configuration Summary"

    local networks storage_path bitcoin_mode txindex
    networks="$(get_config NETWORKS)"
    storage_path="$(get_config STORAGE_PATH)"
    bitcoin_mode="$(get_config BITCOIN_MODE "docker-image")"
    txindex="$(get_config TXINDEX "true")"

    log_info "Networks:       ${networks}"
    log_info "Bitcoin mode:   ${bitcoin_mode}"
    log_info "Storage path:   ${storage_path}"
    log_info "txindex:        ${txindex}"
    log_info "Bitcoin Core:   v$(get_config BITCOIN_VERSION)"
    log_info "Mempool:        v$(get_config MEMPOOL_VERSION)"
    log_info "Electrs:        $(get_config ELECTRS_VERSION)"
    log_info "MariaDB:        $(get_config MARIADB_VERSION)"

    local rpc_enabled
    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED "false")"
    if [[ "${rpc_enabled}" == "true" ]]; then
        log_info "RPC Endpoint:   enabled ($(get_config RPC_METHOD_PROFILE) on port $(get_config RPC_PORT))"
    else
        log_info "RPC Endpoint:   disabled"
    fi

    log_info "TLS:            $(get_config TLS_MODE "none")"

    local cf_enabled
    cf_enabled="$(get_config CLOUDFLARE_TUNNEL_ENABLED "false")"
    if [[ "${cf_enabled}" == "true" ]]; then
        log_info "CF Tunnel:      enabled"
    else
        log_info "CF Tunnel:      disabled"
    fi

    log_info "BTRFS:          $(get_config BTRFS_ENABLED "false")"

    printf '\n' >&2
    log_info "Configuration saved to: ${NODE_CONF}"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    show_banner

    # Load existing config if present
    if [[ -f "${NODE_CONF}" ]]; then
        load_config
        log_info "Loaded existing configuration from ${NODE_CONF}"
        if ! ${NON_INTERACTIVE}; then
            log_info "Previous values will be used as defaults."
        fi
    else
        log_info "No existing configuration found. Starting fresh."
    fi

    # Run all 11 sections
    section_networks
    section_bitcoin_source
    section_versions
    section_storage
    section_bitcoin_options
    section_rpc_endpoint
    section_ports
    section_tls
    section_cloudflare
    section_firewall
    section_credentials

    # Show summary
    show_summary

    # Run config generator
    if ! ${SKIP_GENERATE}; then
        printf '\n' >&2
        if ${NON_INTERACTIVE} || ask_yes_no "Generate all configuration files now?" "y"; then
            log_info "Running generate-config.sh..."
            bash "${_WIZ_DIR}/generate-config.sh"
        else
            log_info "Skipped config generation. Run manually:"
            log_info "  ./scripts/setup/generate-config.sh"
        fi
    fi

    printf '\n' >&2
    log_success "Setup wizard complete!"
    log_info "To start the stack: docker compose up -d"
    log_info "To re-run the wizard: ./scripts/setup/wizard.sh"
}

main "$@"
