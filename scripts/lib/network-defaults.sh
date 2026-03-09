#!/usr/bin/env bash
#
# network-defaults.sh — Shared library providing per-network default values
# for Bitcoin networks. Used by the wizard and config generator to set
# sensible defaults.
#
# Usage:
#   source scripts/lib/network-defaults.sh
#

# Source guard — prevent double-loading
[[ -n "${_NETWORK_DEFAULTS_SH_LOADED:-}" ]] && return 0
_NETWORK_DEFAULTS_SH_LOADED=1

# Source common.sh from the same directory if available
_NETWORK_DEFAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_NETWORK_DEFAULTS_DIR}/common.sh" ]]; then
    # shellcheck source=common.sh
    source "${_NETWORK_DEFAULTS_DIR}/common.sh"
fi

###############################################################################
# Constants
###############################################################################

readonly SUPPORTED_NETWORKS="mainnet signet testnet"

###############################################################################
# get_all_networks()
#   Prints the complete list of supported networks.
###############################################################################
get_all_networks() {
    echo "${SUPPORTED_NETWORKS}"
}

###############################################################################
# validate_network(network)
#   Returns 0 if the given string is a valid network name, 1 otherwise.
###############################################################################
validate_network() {
    local network="${1:-}"

    case "${network}" in
        mainnet|signet|testnet)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# get_default_ports(network)
#   Sets BITCOIN_RPC_PORT, BITCOIN_P2P_PORT, ELECTRS_PORT, and
#   MEMPOOL_API_PORT based on the given network.
###############################################################################
get_default_ports() {
    local network="${1:-}"

    if ! validate_network "${network}"; then
        echo "Error: invalid network '${network}'. Expected one of: ${SUPPORTED_NETWORKS}" >&2
        return 1
    fi

    case "${network}" in
        mainnet)
            BITCOIN_RPC_PORT=8332
            BITCOIN_P2P_PORT=8333
            ;;
        signet)
            BITCOIN_RPC_PORT=38332
            BITCOIN_P2P_PORT=38333
            ;;
        testnet)
            BITCOIN_RPC_PORT=18332
            BITCOIN_P2P_PORT=18333
            ;;
    esac

    # These are the same for all networks — each network runs in its own
    # container so there is no port conflict.
    ELECTRS_PORT=50001
    MEMPOOL_API_PORT=8999
}

###############################################################################
# get_bitcoin_network_flag(network)
#   Prints the bitcoin.conf network activation flag for the given network.
#   Mainnet requires no flag (it is the default).
###############################################################################
get_bitcoin_network_flag() {
    local network="${1:-}"

    if ! validate_network "${network}"; then
        echo "Error: invalid network '${network}'. Expected one of: ${SUPPORTED_NETWORKS}" >&2
        return 1
    fi

    case "${network}" in
        mainnet)
            # Mainnet is the default — no flag needed
            echo ""
            ;;
        signet)
            echo "signet=1"
            ;;
        testnet)
            echo "testnet=1"
            ;;
    esac
}

###############################################################################
# get_default_versions()
#   Sets RECOMMENDED_*_VERSION and SUPPORTED_*_VERSIONS variables with the
#   current recommended software versions.
###############################################################################
get_default_versions() {
    RECOMMENDED_BITCOIN_VERSION="28.1"
    RECOMMENDED_MEMPOOL_VERSION="3.1.0"
    RECOMMENDED_ELECTRS_VERSION="latest"
    RECOMMENDED_MARIADB_VERSION="10.11"
    RECOMMENDED_OPENRESTY_VERSION="alpine"

    SUPPORTED_BITCOIN_VERSIONS=(28.1 28.0 27.2)
    SUPPORTED_MEMPOOL_VERSIONS=(3.1.0 3.0.0)
}

###############################################################################
# get_chain_params(network)
#   Sets comprehensive chain parameters for the given network:
#     CHAIN_NAME, CHAIN_NETWORK, CHAIN_RPC_PORT, CHAIN_P2P_PORT,
#     CHAIN_MAGIC, CHAIN_DEFAULT_DATADIR, CHAIN_APPROX_SIZE, CHAIN_DB_NAME
###############################################################################
get_chain_params() {
    local network="${1:-}"

    if ! validate_network "${network}"; then
        echo "Error: invalid network '${network}'. Expected one of: ${SUPPORTED_NETWORKS}" >&2
        return 1
    fi

    case "${network}" in
        mainnet)
            CHAIN_NAME="Bitcoin Mainnet"
            CHAIN_NETWORK="mainnet"
            CHAIN_RPC_PORT=8332
            CHAIN_P2P_PORT=8333
            CHAIN_MAGIC="f9beb4d9"
            CHAIN_DEFAULT_DATADIR=".bitcoin"
            CHAIN_APPROX_SIZE="600GB+"
            CHAIN_DB_NAME="mempool"
            ;;
        signet)
            CHAIN_NAME="Bitcoin Signet"
            CHAIN_NETWORK="signet"
            CHAIN_RPC_PORT=38332
            CHAIN_P2P_PORT=38333
            CHAIN_MAGIC="0a03cf40"
            CHAIN_DEFAULT_DATADIR=".bitcoin"
            CHAIN_APPROX_SIZE="~5GB"
            CHAIN_DB_NAME="mempool_signet"
            ;;
        testnet)
            CHAIN_NAME="Bitcoin Testnet3"
            CHAIN_NETWORK="testnet"
            CHAIN_RPC_PORT=18332
            CHAIN_P2P_PORT=18333
            CHAIN_MAGIC="0b110907"
            CHAIN_DEFAULT_DATADIR=".bitcoin"
            CHAIN_APPROX_SIZE="~30GB"
            CHAIN_DB_NAME="mempool_testnet"
            ;;
    esac
}

###############################################################################
# get_docker_image(service)
#   Prints the Docker image name:tag for the given service. Uses the
#   corresponding *_VERSION environment variable if set, otherwise falls back
#   to the recommended default.
#
#   Supported services:
#     bitcoin, electrs, mempool-api, mempool-web, mariadb, openresty,
#     cloudflared
###############################################################################
get_docker_image() {
    local service="${1:-}"

    # Ensure version defaults are available
    get_default_versions

    case "${service}" in
        bitcoin)
            # TODO: Consider making the image configurable (BITCOIN_IMAGE in node.conf)
            # to support alternatives like lncm/bitcoind or custom builds.
            local version="${BITCOIN_VERSION:-${RECOMMENDED_BITCOIN_VERSION}}"
            echo "mempool/bitcoin:${version}"
            ;;
        electrs)
            # TODO: Support per-network indexer choice (Fulcrum as alternative).
            # Would add: fulcrum) echo "cculianu/fulcrum:v${FULCRUM_VERSION}" ;;
            local version="${ELECTRS_VERSION:-${RECOMMENDED_ELECTRS_VERSION}}"
            echo "mempool/electrs:${version}"
            ;;
        mempool-api)
            local version="${MEMPOOL_VERSION:-${RECOMMENDED_MEMPOOL_VERSION}}"
            echo "mempool/backend:v${version}"
            ;;
        mempool-web)
            local version="${MEMPOOL_VERSION:-${RECOMMENDED_MEMPOOL_VERSION}}"
            echo "mempool/frontend:v${version}"
            ;;
        mariadb)
            local version="${MARIADB_VERSION:-${RECOMMENDED_MARIADB_VERSION}}"
            echo "mariadb:${version}"
            ;;
        openresty)
            local version="${OPENRESTY_VERSION:-${RECOMMENDED_OPENRESTY_VERSION}}"
            echo "openresty/openresty:${version}"
            ;;
        cloudflared)
            echo "cloudflare/cloudflared:latest"
            ;;
        *)
            echo "Error: unknown service '${service}'. Expected one of: bitcoin electrs mempool-api mempool-web mariadb openresty cloudflared" >&2
            return 1
            ;;
    esac
}
