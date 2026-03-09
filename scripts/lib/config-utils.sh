#!/usr/bin/env bash
# config-utils.sh — shared library for reading/writing node.conf
# Format: key=value pairs, one per line. Lines starting with # are comments.

# Source guard
[[ -n "${_CONFIG_UTILS_SH_LOADED:-}" ]] && return 0
_CONFIG_UTILS_SH_LOADED=1

# Resolve the directory this script lives in
_CONFIG_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common.sh from the same directory if it exists
if [[ -f "${_CONFIG_UTILS_DIR}/common.sh" ]]; then
    # shellcheck source=common.sh
    source "${_CONFIG_UTILS_DIR}/common.sh"
fi

# Ensure PROJECT_ROOT is set (common.sh should provide it; fall back to repo root)
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$(cd "${_CONFIG_UTILS_DIR}/../.." && pwd)"
fi

# Default path to node.conf
NODE_CONF="${NODE_CONF:-${PROJECT_ROOT}/node.conf}"

# Associative array that holds the loaded configuration
declare -A _CONFIG

###############################################################################
# load_config [file]
#   Reads a node.conf file into the _CONFIG associative array.
#   Defaults to $NODE_CONF if no argument is given.
###############################################################################
load_config() {
    local file="${1:-${NODE_CONF}}"

    # Reset the array
    _CONFIG=()

    if [[ ! -f "${file}" ]]; then
        return 0
    fi

    local line key value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip empty lines and comments
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Split on the first '=' only
        key="${line%%=*}"
        value="${line#*=}"

        # Skip lines without an '='
        [[ "${key}" == "${line}" ]] && continue

        # Skip keys that are empty after trimming
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ -z "${key}" ]] && continue

        _CONFIG["${key}"]="${value}"
    done < "${file}"
}

###############################################################################
# get_config KEY [default]
#   Prints the value for KEY from the in-memory config.
#   If KEY is not found, prints the optional default (or empty string).
###############################################################################
get_config() {
    local key="${1:?get_config: KEY is required}"
    local default="${2:-}"

    if [[ -n "${_CONFIG["${key}"]+_set}" ]]; then
        printf '%s\n' "${_CONFIG["${key}"]}"
    else
        printf '%s\n' "${default}"
    fi
}

###############################################################################
# set_config KEY VALUE
#   Updates KEY in both the in-memory _CONFIG array and on disk.
#   If KEY already exists in the file its line is replaced in-place.
#   If KEY does not exist the entry is appended.
###############################################################################
set_config() {
    local key="${1:?set_config: KEY is required}"
    local value="${2:-}"
    local file="${NODE_CONF}"

    # Update in-memory
    _CONFIG["${key}"]="${value}"

    # Ensure the file (and its parent directories) exist
    mkdir -p "$(dirname "${file}")"

    if [[ ! -f "${file}" ]]; then
        printf '%s=%s\n' "${key}" "${value}" > "${file}"
        return 0
    fi

    # Build a temp file to avoid clobbering on failure
    local tmpfile
    tmpfile="$(mktemp "${file}.tmp.XXXXXX")"

    local found=0 line line_key
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Detect if this line sets our key (non-comment, has '=')
        if [[ ! "${line}" =~ ^[[:space:]]*# ]] && [[ "${line}" == *"="* ]]; then
            line_key="${line%%=*}"
            # Trim whitespace from the extracted key
            line_key="${line_key#"${line_key%%[![:space:]]*}"}"
            line_key="${line_key%"${line_key##*[![:space:]]}"}"
            if [[ "${line_key}" == "${key}" ]]; then
                printf '%s=%s\n' "${key}" "${value}" >> "${tmpfile}"
                found=1
                continue
            fi
        fi
        printf '%s\n' "${line}" >> "${tmpfile}"
    done < "${file}"

    if (( found == 0 )); then
        printf '%s=%s\n' "${key}" "${value}" >> "${tmpfile}"
    fi

    mv -f "${tmpfile}" "${file}"
}

###############################################################################
# config_exists KEY
#   Returns 0 if KEY is present in the in-memory config, 1 otherwise.
###############################################################################
config_exists() {
    local key="${1:?config_exists: KEY is required}"
    [[ -n "${_CONFIG["${key}"]+_set}" ]]
}

###############################################################################
# remove_config KEY
#   Removes KEY from both the in-memory _CONFIG array and the file on disk.
###############################################################################
remove_config() {
    local key="${1:?remove_config: KEY is required}"
    local file="${NODE_CONF}"

    # Remove from in-memory array
    unset '_CONFIG['"${key}"']'

    # If there is no file on disk, nothing else to do
    [[ -f "${file}" ]] || return 0

    local tmpfile
    tmpfile="$(mktemp "${file}.tmp.XXXXXX")"

    local line line_key
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ ! "${line}" =~ ^[[:space:]]*# ]] && [[ "${line}" == *"="* ]]; then
            line_key="${line%%=*}"
            line_key="${line_key#"${line_key%%[![:space:]]*}"}"
            line_key="${line_key%"${line_key##*[![:space:]]}"}"
            if [[ "${line_key}" == "${key}" ]]; then
                continue
            fi
        fi
        printf '%s\n' "${line}" >> "${tmpfile}"
    done < "${file}"

    mv -f "${tmpfile}" "${file}"
}

###############################################################################
# backup_config
#   Creates a timestamped copy of node.conf:
#     node.conf  →  node.conf.backup.YYYYMMDD_HHMMSS
###############################################################################
backup_config() {
    local file="${NODE_CONF}"

    if [[ ! -f "${file}" ]]; then
        echo "backup_config: ${file} does not exist, nothing to back up" >&2
        return 1
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local backup="${file}.backup.${timestamp}"

    cp -a "${file}" "${backup}"
    printf '%s\n' "${backup}"
}

###############################################################################
# get_networks
#   Prints the NETWORKS value as space-separated tokens (one per line) so the
#   caller can capture them into a bash array:
#     mapfile -t nets < <(get_networks)
###############################################################################
get_networks() {
    local raw
    raw="$(get_config NETWORKS)"
    [[ -z "${raw}" ]] && return 0

    local IFS=','
    local -a nets=( ${raw} )

    local net
    for net in "${nets[@]}"; do
        # Trim whitespace
        net="${net#"${net%%[![:space:]]*}"}"
        net="${net%"${net##*[![:space:]]}"}"
        [[ -n "${net}" ]] && printf '%s\n' "${net}"
    done
}

###############################################################################
# is_network_enabled NETWORK
#   Returns 0 if NETWORK appears in the NETWORKS list, 1 otherwise.
#   Comparison is case-insensitive.
###############################################################################
is_network_enabled() {
    local target="${1:?is_network_enabled: NETWORK is required}"
    target="${target,,}"  # lowercase

    local net
    while IFS= read -r net; do
        [[ "${net,,}" == "${target}" ]] && return 0
    done < <(get_networks)

    return 1
}

###############################################################################
# get_network_config NETWORK KEY [default]
#   Looks up a per-network config key.  For example:
#     get_network_config mainnet BITCOIN_RPC_PORT
#   First checks MAINNET_BITCOIN_RPC_PORT, then falls back to BITCOIN_RPC_PORT,
#   and finally to the optional default value.
###############################################################################
get_network_config() {
    local network="${1:?get_network_config: NETWORK is required}"
    local key="${2:?get_network_config: KEY is required}"
    local default="${3:-}"

    local prefixed_key="${network^^}_${key}"

    if config_exists "${prefixed_key}"; then
        get_config "${prefixed_key}"
    elif config_exists "${key}"; then
        get_config "${key}"
    else
        printf '%s\n' "${default}"
    fi
}
