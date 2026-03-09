#!/usr/bin/env bash
# ==============================================================================
# setup-tunnel.sh — Configure Cloudflare Tunnel for the mempool stack
#
# Guides the user through setting up a Cloudflare Tunnel to securely expose
# the mempool web interface and optional RPC endpoint without opening ports.
#
# Usage:
#   ./scripts/tunnel/setup-tunnel.sh
#   ./scripts/tunnel/setup-tunnel.sh --token TOKEN
#   ./scripts/tunnel/setup-tunnel.sh --non-interactive --token TOKEN
#
# Options:
#   --token TOKEN         Cloudflare Tunnel token (skip interactive prompt)
#   --non-interactive     Run without interactive prompts (requires --token)
#   -h, --help            Show this help message
# ==============================================================================
set -euo pipefail

# ==============================================================================
# Source shared libraries
# ==============================================================================
_TUNNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${_TUNNEL_DIR}/../lib/common.sh"
# shellcheck source=../lib/config-utils.sh
source "${_TUNNEL_DIR}/../lib/config-utils.sh"

# ==============================================================================
# Defaults
# ==============================================================================
TUNNEL_TOKEN=""
NON_INTERACTIVE=false

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            TUNNEL_TOKEN="${2:?--token requires a value}"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: setup-tunnel.sh [OPTIONS]

Configure Cloudflare Tunnel for the mempool stack.

Options:
  --token TOKEN         Cloudflare Tunnel token (skip interactive prompt)
  --non-interactive     Run without interactive prompts (requires --token)
  -h, --help            Show this help message

Prerequisites:
  1. A Cloudflare account with a domain configured
  2. A Cloudflare Tunnel created in the Cloudflare dashboard

Steps to create a tunnel:
  1. Go to https://dash.cloudflare.com → Zero Trust → Access → Tunnels
  2. Click "Create a tunnel"
  3. Choose "Cloudflared" connector
  4. Name your tunnel (e.g., "mempool-node")
  5. Copy the tunnel token from the install command
  6. Configure public hostnames:
     - mempool.yourdomain.com → http://localhost:80 (web interface)
     - rpc.yourdomain.com → http://localhost:3000 (RPC, optional)
  7. Run this script with the token

What this does:
  - Saves CLOUDFLARE_TUNNEL_ENABLED=true and the token to node.conf
  - Regenerates configuration (firewall rules become tunnel-aware)
  - The cloudflared container in docker-compose will connect using this token
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
# Main
# ==============================================================================
log_header "Cloudflare Tunnel Setup"

# Load existing config if available
if [[ -f "${NODE_CONF}" ]]; then
    load_config
fi

# Check if already configured
existing_token="$(get_config CLOUDFLARE_TUNNEL_TOKEN "")"
if [[ -n "${existing_token}" ]]; then
    log_warn "A Cloudflare Tunnel token is already configured."
    if ${NON_INTERACTIVE}; then
        log_info "Overwriting existing token (non-interactive mode)."
    else
        if ! ask_yes_no "Overwrite existing tunnel configuration?" "n"; then
            log_info "Keeping existing configuration."
            exit 0
        fi
    fi
fi

# Get the tunnel token
if [[ -z "${TUNNEL_TOKEN}" ]]; then
    if ${NON_INTERACTIVE}; then
        log_error "--token is required in non-interactive mode."
        exit 1
    fi

    echo "" >&2
    log_info "To set up a Cloudflare Tunnel, you need a tunnel token."
    echo "" >&2
    log_info "How to get a tunnel token:"
    log_info "  1. Go to https://dash.cloudflare.com"
    log_info "  2. Navigate to: Zero Trust -> Access -> Tunnels"
    log_info "  3. Click 'Create a tunnel'"
    log_info "  4. Choose 'Cloudflared' as the connector"
    log_info "  5. Name your tunnel (e.g., 'mempool-node')"
    log_info "  6. Copy the token from the install command"
    log_info "     (it looks like: eyJhIjoiNjM...)"
    echo "" >&2
    log_info "  7. Configure public hostnames in the dashboard:"
    log_info "     - mempool.yourdomain.com -> http://localhost:80"
    log_info "     - rpc.yourdomain.com -> http://localhost:3000 (optional)"
    echo "" >&2

    TUNNEL_TOKEN=$(ask_secret "Paste your Cloudflare Tunnel token")

    if [[ -z "${TUNNEL_TOKEN}" ]]; then
        log_error "No token provided. Aborting."
        exit 1
    fi
fi

# Basic token validation (should be a long base64-ish string)
if [[ ${#TUNNEL_TOKEN} -lt 20 ]]; then
    log_warn "Token seems unusually short (${#TUNNEL_TOKEN} characters). Double-check it is correct."
fi

# Save to node.conf
log_info "Saving tunnel configuration to node.conf..."
set_config "CLOUDFLARE_TUNNEL_ENABLED" "true"
set_config "CLOUDFLARE_TUNNEL_TOKEN" "${TUNNEL_TOKEN}"

# Prompt for hostnames if interactive
if ! ${NON_INTERACTIVE}; then
    echo "" >&2
    log_info "Optional: Configure hostnames for config generation."
    log_info "(These should match what you configured in the Cloudflare dashboard.)"
    echo "" >&2

    current_web_host="$(get_config CF_HOSTNAME_WEB "")"
    web_host=$(ask_input "Web hostname (e.g., mempool.yourdomain.com)" "${current_web_host}")
    if [[ -n "${web_host}" ]]; then
        set_config "CF_HOSTNAME_WEB" "${web_host}"
    fi

    rpc_enabled="$(get_config RPC_ENDPOINT_ENABLED false)"
    if [[ "${rpc_enabled}" == "true" ]]; then
        current_rpc_host="$(get_config CF_HOSTNAME_RPC "")"
        rpc_host=$(ask_input "RPC hostname (e.g., rpc.yourdomain.com, or empty to skip)" "${current_rpc_host}")
        if [[ -n "${rpc_host}" ]]; then
            set_config "CF_HOSTNAME_RPC" "${rpc_host}"
        fi
    fi
fi

log_success "Tunnel configuration saved to node.conf."

# Offer to regenerate config
regen=false
if ${NON_INTERACTIVE}; then
    regen=true
else
    if ask_yes_no "Regenerate configuration files now?" "y"; then
        regen=true
    fi
fi

if ${regen}; then
    log_info "Regenerating configuration..."
    bash "${PROJECT_ROOT}/scripts/setup/generate-config.sh"
    log_success "Configuration regenerated with tunnel-aware settings."
    log_info "Firewall rules have been updated to restrict public port access."
    log_info "Web/RPC traffic will flow through the Cloudflare Tunnel."
else
    log_info "Run ./scripts/setup/generate-config.sh to apply changes."
fi

echo "" >&2
log_success "Cloudflare Tunnel setup complete."
log_info "Next steps:"
log_info "  1. Run: docker compose up -d"
log_info "  2. The cloudflared container will connect to Cloudflare automatically."
log_info "  3. Verify at: https://dash.cloudflare.com -> Zero Trust -> Tunnels"
