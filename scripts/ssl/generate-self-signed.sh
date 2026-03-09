#!/usr/bin/env bash
# ==============================================================================
# generate-self-signed.sh — Generate a self-signed SSL certificate
#
# Creates a self-signed certificate and private key for use with OpenResty.
#
# Usage:
#   ./scripts/ssl/generate-self-signed.sh [--domain DOMAIN] [--dry-run]
#
# Options:
#   --domain DOMAIN   Domain name for the certificate (default: localhost)
#   --dry-run         Show what would be done without writing files
#   -h, --help        Show this help message
#
# Output:
#   config/openresty/ssl/server.crt   — Self-signed certificate
#   config/openresty/ssl/server.key   — Private key
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
DOMAIN="localhost"
DRY_RUN=false
CERT_DIR="${PROJECT_ROOT}/config/openresty/ssl"
CERT_DAYS=365
KEY_BITS=2048

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="${2:?--domain requires a value}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: generate-self-signed.sh [OPTIONS]

Generate a self-signed SSL certificate for the OpenResty proxy.

Options:
  --domain DOMAIN   Domain name for the certificate (default: localhost)
  --dry-run         Show what would be done without writing files
  -h, --help        Show this help message

Output files:
  config/openresty/ssl/server.crt   Self-signed certificate (PEM)
  config/openresty/ssl/server.key   Private key (PEM)

Certificate details:
  - 2048-bit RSA key
  - SHA256 signature
  - 365-day validity
  - Includes Subject Alternative Name (SAN)
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
# Try to read domain from node.conf if not specified on command line
# ==============================================================================
if [[ "${DOMAIN}" == "localhost" ]] && [[ -f "${NODE_CONF}" ]]; then
    load_config
    local_domain="$(get_config DOMAIN_WEB "")"
    if [[ -n "${local_domain}" ]] && [[ "${local_domain}" != "_" ]]; then
        DOMAIN="${local_domain}"
        log_info "Using domain from node.conf: ${DOMAIN}"
    fi
fi

# ==============================================================================
# Main
# ==============================================================================
log_header "Generating self-signed SSL certificate"

# Check for openssl
if ! command -v openssl &>/dev/null; then
    log_error "openssl is required but not installed."
    log_error "Install with: sudo apt-get install openssl"
    exit 1
fi

log_info "Domain: ${DOMAIN}"
log_info "Key size: ${KEY_BITS}-bit RSA"
log_info "Validity: ${CERT_DAYS} days"
log_info "Output directory: ${CERT_DIR}"

if ${DRY_RUN}; then
    log_warn "Dry-run mode — no files will be written."
    log_info "Would generate:"
    log_info "  ${CERT_DIR}/server.key"
    log_info "  ${CERT_DIR}/server.crt"
    exit 0
fi

# Create output directory
mkdir -p "${CERT_DIR}"

# Generate the self-signed certificate with SAN
openssl req -x509 \
    -newkey "rsa:${KEY_BITS}" \
    -keyout "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.crt" \
    -sha256 \
    -days "${CERT_DAYS}" \
    -nodes \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1" \
    2>/dev/null

# Set secure permissions
chmod 600 "${CERT_DIR}/server.key"
chmod 644 "${CERT_DIR}/server.crt"

log_success "Self-signed certificate generated:"
log_info "  Certificate: ${CERT_DIR}/server.crt"
log_info "  Private key: ${CERT_DIR}/server.key"
log_info "  Valid for: ${CERT_DAYS} days"
log_warn "Self-signed certificates will show browser warnings. Use Let's Encrypt for production."
