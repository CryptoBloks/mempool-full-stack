#!/usr/bin/env bash
# ==============================================================================
# common.sh - Shared library for mempool.space full-stack-docker scripts
#
# Provides colors, logging, interactive prompts, validators, and utilities.
# Source this file from other scripts; do not execute it directly.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# ==============================================================================

# ------------------------------------------------------------------------------
# Double-source guard
# ------------------------------------------------------------------------------
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ------------------------------------------------------------------------------
# Strict mode — only when executed directly (not sourced)
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# ------------------------------------------------------------------------------
# Path resolution
# ------------------------------------------------------------------------------
# PROJECT_ROOT resolves to the repository root (two levels above scripts/lib/).
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROJECT_ROOT

# SCRIPT_DIR resolves to the directory of the *calling* script. When common.sh
# is sourced, BASH_SOURCE[1] is the sourcing script. If executed directly (e.g.
# for testing), fall back to BASH_SOURCE[0].
if [[ "${#BASH_SOURCE[@]}" -gt 1 ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
readonly SCRIPT_DIR

# ------------------------------------------------------------------------------
# Colors (respect NO_COLOR — see https://no-color.org)
# ------------------------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    _CLR_RED=$'\033[0;31m'
    _CLR_GREEN=$'\033[0;32m'
    _CLR_YELLOW=$'\033[0;33m'
    _CLR_BLUE=$'\033[0;34m'
    _CLR_CYAN=$'\033[0;36m'
    _CLR_BOLD=$'\033[1m'
    _CLR_RESET=$'\033[0m'
else
    _CLR_RED=''
    _CLR_GREEN=''
    _CLR_YELLOW=''
    _CLR_BLUE=''
    _CLR_CYAN=''
    _CLR_BOLD=''
    _CLR_RESET=''
fi

# ==============================================================================
# LOGGING
# ==============================================================================

# log_info MESSAGE...
#   Print an informational message to stderr.
log_info() {
    printf '%s[INFO]%s  %s\n' "${_CLR_BLUE}" "${_CLR_RESET}" "$*" >&2
}

# log_warn MESSAGE...
#   Print a warning message to stderr.
log_warn() {
    printf '%s[WARN]%s  %s\n' "${_CLR_YELLOW}" "${_CLR_RESET}" "$*" >&2
}

# log_error MESSAGE...
#   Print an error message to stderr.
log_error() {
    printf '%s[ERROR]%s %s\n' "${_CLR_RED}" "${_CLR_RESET}" "$*" >&2
}

# log_success MESSAGE...
#   Print a success message to stderr.
log_success() {
    printf '%s[OK]%s    %s\n' "${_CLR_GREEN}" "${_CLR_RESET}" "$*" >&2
}

# log_header TITLE
#   Print a boxed section header to stderr.
log_header() {
    local title="$1"
    local width=$(( ${#title} + 4 ))
    local border
    border=$(printf '%*s' "$width" '' | tr ' ' '=')

    printf '\n%s%s%s\n' "${_CLR_BOLD}${_CLR_CYAN}" "$border" "${_CLR_RESET}" >&2
    printf '%s  %s  %s\n' "${_CLR_BOLD}${_CLR_CYAN}" "$title" "${_CLR_RESET}" >&2
    printf '%s%s%s\n\n' "${_CLR_BOLD}${_CLR_CYAN}" "$border" "${_CLR_RESET}" >&2
}

# ==============================================================================
# INTERACTIVE PROMPTS
# ==============================================================================

# ask_yes_no QUESTION [DEFAULT]
#   Prompt the user for a yes/no answer.
#   DEFAULT is "y" or "n" (case-insensitive); defaults to "y" if omitted.
#   Returns 0 for yes, 1 for no.
ask_yes_no() {
    local question="$1"
    local default="${2:-y}"
    default="${default,,}"  # lowercase

    local hint
    if [[ "$default" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    local answer
    while true; do
        printf '%s [%s]: ' "$question" "$hint" >&2
        read -r answer
        answer="${answer,,}"  # lowercase

        if [[ -z "$answer" ]]; then
            answer="$default"
        fi

        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     log_warn "Please answer y or n." ;;
        esac
    done
}

# ask_input PROMPT [DEFAULT]
#   Prompt the user for a text value.
#   Shows "[DEFAULT]" hint when a default is provided.
#   Prints the final value to stdout.
ask_input() {
    local prompt="$1"
    local default="${2:-}"

    local hint=""
    if [[ -n "$default" ]]; then
        hint=" [${default}]"
    fi

    local value
    printf '%s%s: ' "$prompt" "$hint" >&2
    read -r value

    if [[ -z "$value" ]]; then
        value="$default"
    fi

    printf '%s' "$value"
}

# ask_choice PROMPT OPTIONS_ARRAY [DEFAULT_INDEX]
#   Present a numbered list and let the user pick one.
#   OPTIONS_ARRAY is the name of a bash array variable.
#   DEFAULT_INDEX is 1-based; defaults to 1.
#   Prints the selected *value* (not the index) to stdout.
#
#   Example:
#     options=("mainnet" "testnet" "signet")
#     network=$(ask_choice "Select network" options 1)
ask_choice() {
    local prompt="$1"
    local -n _choices=$2
    local default_idx="${3:-1}"

    if [[ ${#_choices[@]} -eq 0 ]]; then
        log_error "ask_choice: options array is empty."
        return 1
    fi

    if [[ "$default_idx" -lt 1 || "$default_idx" -gt ${#_choices[@]} ]]; then
        log_error "ask_choice: default index ${default_idx} is out of range (1..${#_choices[@]})."
        return 1
    fi

    printf '%s\n' "$prompt" >&2
    local i
    for i in "${!_choices[@]}"; do
        local num=$(( i + 1 ))
        local marker=""
        if [[ "$num" -eq "$default_idx" ]]; then
            marker=" ${_CLR_CYAN}(default)${_CLR_RESET}"
        fi
        printf '  %s%d%s) %s%s\n' "${_CLR_BOLD}" "$num" "${_CLR_RESET}" "${_choices[$i]}" "$marker" >&2
    done

    local selection
    while true; do
        printf 'Choice [%d]: ' "$default_idx" >&2
        read -r selection

        if [[ -z "$selection" ]]; then
            selection="$default_idx"
        fi

        # Validate: must be an integer in range
        if [[ "$selection" =~ ^[0-9]+$ ]] \
            && [[ "$selection" -ge 1 ]] \
            && [[ "$selection" -le ${#_choices[@]} ]]; then
            printf '%s' "${_choices[$(( selection - 1 ))]}"
            return 0
        fi

        log_warn "Invalid selection. Enter a number between 1 and ${#_choices[@]}."
    done
}

# ask_secret PROMPT
#   Prompt the user for a secret value (input is not echoed).
#   Prints the value to stdout.
ask_secret() {
    local prompt="$1"

    local secret
    printf '%s: ' "$prompt" >&2
    read -rs secret
    printf '\n' >&2  # newline after silent read

    printf '%s' "$secret"
}

# ==============================================================================
# VALIDATORS
# ==============================================================================

# validate_ip ADDRESS
#   Return 0 if ADDRESS is a valid IPv4 address, 1 otherwise.
validate_ip() {
    local ip="$1"

    # Must match exactly four dot-separated octets
    if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        return 1
    fi

    # Each octet must be 0-255
    local i
    for i in 1 2 3 4; do
        local octet="${BASH_REMATCH[$i]}"
        if [[ "$octet" -gt 255 ]]; then
            return 1
        fi
        # Reject leading zeros (e.g. 01, 001) except for bare "0"
        if [[ "${#octet}" -gt 1 && "${octet:0:1}" == "0" ]]; then
            return 1
        fi
    done

    return 0
}

# validate_port PORT
#   Return 0 if PORT is a valid TCP/UDP port (integer 1-65535), 1 otherwise.
validate_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        return 1
    fi

    return 0
}

# validate_path PATH
#   Return 0 if PATH is an absolute path (starts with /), 1 otherwise.
#   Does NOT check whether the path exists.
validate_path() {
    local path="$1"

    if [[ "$path" != /* ]]; then
        return 1
    fi

    # Reject empty segments that would indicate a malformed path (e.g. bare "/")
    # is technically valid as root, so we allow it.
    return 0
}

# validate_url URL
#   Return 0 if URL looks like a valid HTTP(S) URL, 1 otherwise.
validate_url() {
    local url="$1"

    # Basic format: scheme://host with optional port, path, query, fragment.
    # The host must start with an alphanumeric character. We store the regex
    # in a variable to avoid bash parsing issues with special characters in
    # character classes.
    local _url_re='^https?://[A-Za-z0-9][A-Za-z0-9._~:/%?#@!$&'\''*+,;=-]*$'
    if [[ "$url" =~ $_url_re ]]; then
        return 0
    fi

    return 1
}

# ==============================================================================
# UTILITIES
# ==============================================================================

# require_command COMMAND [INSTALL_HINT]
#   Check that COMMAND is available on PATH. If not, print an error with an
#   optional install hint and return 1.
require_command() {
    local cmd="$1"
    local hint="${2:-}"

    if command -v "$cmd" &>/dev/null; then
        return 0
    fi

    local msg="Required command '${cmd}' is not installed."
    if [[ -n "$hint" ]]; then
        msg+=" Install with: ${hint}"
    fi

    log_error "$msg"
    return 1
}

# generate_password [LENGTH]
#   Generate a random hex string of LENGTH characters (default 32).
#   Prints the password to stdout.
generate_password() {
    local length="${1:-32}"

    if [[ ! "$length" =~ ^[0-9]+$ ]] || [[ "$length" -lt 1 ]]; then
        log_error "generate_password: length must be a positive integer."
        return 1
    fi

    # We need ceil(length/2) bytes to produce `length` hex characters.
    local bytes=$(( (length + 1) / 2 ))

    local password
    if command -v xxd &>/dev/null; then
        password=$(head -c "$bytes" /dev/urandom | xxd -p | tr -d '\n' | head -c "$length")
    elif command -v od &>/dev/null; then
        password=$(head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c "$length")
    else
        log_error "generate_password: neither 'xxd' nor 'od' found."
        return 1
    fi

    printf '%s' "$password"
}
