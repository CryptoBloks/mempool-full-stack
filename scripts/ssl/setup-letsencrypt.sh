#!/usr/bin/env bash
# ==============================================================================
# setup-letsencrypt.sh — Obtain and configure a Let's Encrypt SSL certificate
#
# Uses certbot (preferred) or acme.sh (fallback) to obtain a trusted SSL
# certificate from Let's Encrypt. Sets up automatic renewal.
#
# Usage:
#   ./scripts/ssl/setup-letsencrypt.sh --domain DOMAIN --email EMAIL
#   ./scripts/ssl/setup-letsencrypt.sh --dry-run --domain DOMAIN --email EMAIL
#
# Options:
#   --domain DOMAIN   Domain name for the certificate (required)
#   --email EMAIL     Email for Let's Encrypt notifications (required)
#   --dry-run         Test without actually obtaining a certificate
#   --staging         Use Let's Encrypt staging server (for testing)
#   -h, --help        Show this help message
#
# Certificates are stored in the standard Let's Encrypt path:
#   /etc/letsencrypt/live/DOMAIN/fullchain.pem
#   /etc/letsencrypt/live/DOMAIN/privkey.pem
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Source shared libraries
# ==============================================================================
_SSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_SSL_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_SSL_DIR}/../lib/config-utils.sh"

# ==============================================================================
# Defaults
# ==============================================================================
DOMAIN=""
EMAIL=""
DRY_RUN=false
USE_STAGING=false

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="${2:?--domain requires a value}"
            shift 2
            ;;
        --email)
            EMAIL="${2:?--email requires a value}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --staging)
            USE_STAGING=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: setup-letsencrypt.sh --domain DOMAIN --email EMAIL [OPTIONS]

Obtain a Let's Encrypt SSL certificate using certbot or acme.sh.

Required:
  --domain DOMAIN   Domain name for the certificate
  --email EMAIL     Email address for Let's Encrypt notifications

Options:
  --dry-run         Show what would be done without obtaining a certificate
  --staging         Use Let's Encrypt staging server (for testing)
  -h, --help        Show this help message

Prerequisites:
  - Domain must resolve to this server's public IP
  - Port 80 must be accessible from the internet (for HTTP-01 challenge)
  - Either certbot or acme.sh must be installed (or will be installed)

Certificate paths (standard Let's Encrypt locations):
  /etc/letsencrypt/live/DOMAIN/fullchain.pem
  /etc/letsencrypt/live/DOMAIN/privkey.pem

Auto-renewal:
  A cron job or systemd timer is configured for automatic renewal.
  OpenResty is reloaded after each successful renewal.
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
# Try to read values from node.conf if not specified on command line
# ==============================================================================
if [[ -f "${NODE_CONF}" ]]; then
    load_config
    if [[ -z "${DOMAIN}" ]]; then
        DOMAIN="$(get_config DOMAIN_WEB "")"
    fi
    if [[ -z "${EMAIL}" ]]; then
        EMAIL="$(get_config LETSENCRYPT_EMAIL "")"
    fi
fi

# ==============================================================================
# Validate inputs
# ==============================================================================
if [[ -z "${DOMAIN}" ]]; then
    log_error "--domain is required (or set DOMAIN_WEB in node.conf)"
    exit 1
fi

if [[ -z "${EMAIL}" ]]; then
    log_error "--email is required (or set LETSENCRYPT_EMAIL in node.conf)"
    exit 1
fi

if [[ "${DOMAIN}" == "_" ]] || [[ "${DOMAIN}" == "localhost" ]]; then
    log_error "Domain '${DOMAIN}' is not valid for Let's Encrypt."
    log_error "Let's Encrypt requires a real, publicly-resolvable domain name."
    exit 1
fi

# ==============================================================================
# detect_ssl_tool
#   Finds certbot or acme.sh. Sets SSL_TOOL to "certbot" or "acme.sh".
# ==============================================================================
detect_ssl_tool() {
    if command -v certbot &>/dev/null; then
        SSL_TOOL="certbot"
        log_info "Found certbot: $(command -v certbot)"
        return 0
    fi

    if command -v acme.sh &>/dev/null; then
        SSL_TOOL="acme.sh"
        log_info "Found acme.sh: $(command -v acme.sh)"
        return 0
    fi

    # Check common acme.sh install locations
    local acme_paths=(
        "${HOME}/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
    )
    local p
    for p in "${acme_paths[@]}"; do
        if [[ -x "${p}" ]]; then
            SSL_TOOL="acme.sh"
            ACME_SH_PATH="${p}"
            log_info "Found acme.sh: ${p}"
            return 0
        fi
    done

    return 1
}

# ==============================================================================
# setup_renewal_hook
#   Creates a renewal hook that reloads OpenResty after certificate renewal.
# ==============================================================================
setup_renewal_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    if [[ -d "/etc/letsencrypt/renewal-hooks" ]]; then
        mkdir -p "${hook_dir}"
        cat > "${hook_dir}/reload-openresty.sh" <<'HOOK'
#!/bin/bash
# Reload OpenResty after Let's Encrypt certificate renewal
if command -v docker &>/dev/null; then
    docker exec openresty nginx -s reload 2>/dev/null || true
fi
HOOK
        chmod +x "${hook_dir}/reload-openresty.sh"
        log_success "Installed renewal hook: ${hook_dir}/reload-openresty.sh"
    fi
}

# ==============================================================================
# setup_acme_renewal_cron
#   Adds a cron entry for acme.sh auto-renewal with OpenResty reload.
# ==============================================================================
setup_acme_renewal_cron() {
    local acme_cmd="${ACME_SH_PATH:-acme.sh}"
    local cron_entry="0 3 * * * ${acme_cmd} --cron --home \"${HOME}/.acme.sh\" --reloadcmd \"docker exec openresty nginx -s reload 2>/dev/null || true\" > /dev/null 2>&1"

    # Check if already installed
    if crontab -l 2>/dev/null | grep -qF "acme.sh --cron"; then
        log_info "acme.sh renewal cron already exists."
        return 0
    fi

    (crontab -l 2>/dev/null; echo "${cron_entry}") | crontab -
    log_success "Installed acme.sh renewal cron (runs daily at 03:00)."
}

# ==============================================================================
# obtain_with_certbot
#   Uses certbot to obtain a certificate via HTTP-01 challenge.
# ==============================================================================
obtain_with_certbot() {
    log_info "Obtaining certificate with certbot..."

    local -a certbot_args=(
        certonly
        --standalone
        --non-interactive
        --agree-tos
        --email "${EMAIL}"
        -d "${DOMAIN}"
        --preferred-challenges http
    )

    if ${USE_STAGING}; then
        certbot_args+=(--staging)
        log_warn "Using Let's Encrypt STAGING server (certificates will NOT be trusted)."
    fi

    if ${DRY_RUN}; then
        certbot_args+=(--dry-run)
        log_warn "Dry-run mode — certificate will NOT be saved."
    fi

    certbot "${certbot_args[@]}"
    local rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_error "certbot failed (exit code ${rc})."
        log_error "Common issues:"
        log_error "  - Port 80 is not accessible from the internet"
        log_error "  - Domain does not resolve to this server's IP"
        log_error "  - Rate limit exceeded (use --staging for testing)"
        return ${rc}
    fi

    if ! ${DRY_RUN}; then
        setup_renewal_hook
        log_success "Certificate obtained and stored at:"
        log_info "  /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        log_info "  /etc/letsencrypt/live/${DOMAIN}/privkey.pem"

        # Enable auto-renewal timer if systemd is available
        if command -v systemctl &>/dev/null; then
            systemctl enable --now certbot.timer 2>/dev/null || true
            log_info "Certbot auto-renewal timer enabled."
        fi
    fi
}

# ==============================================================================
# obtain_with_acme
#   Uses acme.sh to obtain a certificate via HTTP-01 challenge.
# ==============================================================================
obtain_with_acme() {
    local acme_cmd="${ACME_SH_PATH:-acme.sh}"
    log_info "Obtaining certificate with acme.sh..."

    local -a acme_args=(
        --issue
        --standalone
        -d "${DOMAIN}"
        --accountemail "${EMAIL}"
    )

    if ${USE_STAGING}; then
        acme_args+=(--staging)
        log_warn "Using Let's Encrypt STAGING server (certificates will NOT be trusted)."
    fi

    if ${DRY_RUN}; then
        log_warn "Dry-run mode — showing what would be done."
        log_info "Would run: ${acme_cmd} ${acme_args[*]}"
        log_info "Would install certificate to /etc/letsencrypt/live/${DOMAIN}/"
        return 0
    fi

    "${acme_cmd}" "${acme_args[@]}"
    local rc=$?

    if [[ ${rc} -ne 0 ]]; then
        log_error "acme.sh failed (exit code ${rc})."
        log_error "Common issues:"
        log_error "  - Port 80 is not accessible from the internet"
        log_error "  - Domain does not resolve to this server's IP"
        return ${rc}
    fi

    # Install certificate to standard Let's Encrypt path
    local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
    mkdir -p "${cert_dir}"

    "${acme_cmd}" --install-cert -d "${DOMAIN}" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --key-file "${cert_dir}/privkey.pem" \
        --reloadcmd "docker exec openresty nginx -s reload 2>/dev/null || true"

    setup_acme_renewal_cron

    log_success "Certificate obtained and installed:"
    log_info "  ${cert_dir}/fullchain.pem"
    log_info "  ${cert_dir}/privkey.pem"
}

# ==============================================================================
# Main
# ==============================================================================
log_header "Let's Encrypt SSL Certificate Setup"

log_info "Domain: ${DOMAIN}"
log_info "Email: ${EMAIL}"

# Check for root (needed for port 80 binding and /etc/letsencrypt)
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! ${DRY_RUN}; then
    log_error "This script must be run as root (or with sudo) to bind port 80 and write to /etc/letsencrypt."
    exit 1
fi

# Detect available SSL tool
if ! detect_ssl_tool; then
    log_error "Neither certbot nor acme.sh is installed."
    log_error "Install certbot: sudo apt-get install certbot"
    log_error "  or"
    log_error "Install acme.sh: curl https://get.acme.sh | sh"
    exit 1
fi

log_info "Using SSL tool: ${SSL_TOOL}"

# Stop OpenResty temporarily if running (port 80 needed for challenge)
local_openresty_stopped=false
if ! ${DRY_RUN} && command -v docker &>/dev/null; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^openresty$'; then
        log_info "Stopping OpenResty temporarily for HTTP-01 challenge..."
        docker stop openresty 2>/dev/null || true
        local_openresty_stopped=true
    fi
fi

# Obtain the certificate
rc=0
case "${SSL_TOOL}" in
    certbot)
        obtain_with_certbot || rc=$?
        ;;
    acme.sh)
        obtain_with_acme || rc=$?
        ;;
esac

# Restart OpenResty if we stopped it
if ${local_openresty_stopped}; then
    log_info "Restarting OpenResty..."
    docker start openresty 2>/dev/null || true
fi

if [[ ${rc} -ne 0 ]]; then
    exit ${rc}
fi

if ! ${DRY_RUN}; then
    log_success "Let's Encrypt setup complete."
    log_info "Certificates will auto-renew before expiry."
    log_info "Make sure TLS_MODE=letsencrypt is set in node.conf and re-run generate-config.sh."
fi
