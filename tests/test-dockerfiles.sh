#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0 FAIL=0 TOTAL=0

assert_file_contains() {
    local label="$1" filepath="$2" pattern="$3"
    ((TOTAL++)) || true
    if grep -qE "${pattern}" "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (pattern not found: %s)\n' "${label}" "${pattern}"
    fi
}

assert_file_not_contains() {
    local label="$1" filepath="$2" pattern="$3"
    ((TOTAL++)) || true
    if ! grep -qE "${pattern}" "${filepath}" 2>/dev/null; then
        ((PASS++)) || true
        printf '  \033[0;32m✓\033[0m %s\n' "${label}"
    else
        ((FAIL++)) || true
        printf '  \033[0;31m✗\033[0m %s (unexpected pattern found: %s)\n' "${label}" "${pattern}"
    fi
}

echo "=== Dockerfile Validation ==="
echo ""

# --- Dockerfile.bitcoin ---
BTC="${PROJECT_ROOT}/docker/Dockerfile.bitcoin"
echo "--- Dockerfile.bitcoin ---"
assert_file_contains "Has FROM statement" "${BTC}" "^FROM "
assert_file_contains "Has ARG BITCOIN_VERSION" "${BTC}" "^ARG BITCOIN_VERSION"
assert_file_contains "Creates bitcoin user" "${BTC}" "useradd.*bitcoin"
assert_file_contains "Creates /data/.bitcoin" "${BTC}" "mkdir.*data/.bitcoin"
assert_file_contains "Sets ENTRYPOINT to bitcoind" "${BTC}" 'ENTRYPOINT.*bitcoind'
assert_file_contains "ENTRYPOINT uses -datadir=/data/.bitcoin" "${BTC}" 'datadir=/data/.bitcoin'
assert_file_contains "Exposes RPC/P2P ports" "${BTC}" "EXPOSE.*8332"

# Bug M6: misleading comments — says "Build-from-source" but downloads binary
assert_file_not_contains "[M6] No misleading 'build-from-source' comment when downloading binary" "${BTC}" "Build-from-source"
# Bug M6: unnecessary build dependencies for a binary download
assert_file_not_contains "[M6] No unnecessary autoconf dependency" "${BTC}" "autoconf"
assert_file_not_contains "[M6] No unnecessary libboost dependency" "${BTC}" "libboost"
# Bug M6: should verify SHA256 of downloaded binary
assert_file_contains "[M6] Has SHA256 verification" "${BTC}" "sha256sum|SHA256SUMS"

echo ""

# --- Dockerfile.fulcrum ---
FUL="${PROJECT_ROOT}/docker/Dockerfile.fulcrum"
echo "--- Dockerfile.fulcrum ---"
assert_file_contains "Has FROM statement" "${FUL}" "^FROM "
assert_file_contains "Has ARG FULCRUM_VERSION" "${FUL}" "^ARG FULCRUM_VERSION"
assert_file_contains "Creates fulcrum user" "${FUL}" "useradd.*fulcrum"
assert_file_contains "Sets ENTRYPOINT to Fulcrum" "${FUL}" 'ENTRYPOINT.*Fulcrum'
assert_file_contains "Exposes ports 50001 50002" "${FUL}" "EXPOSE.*50001"

# Bug C5: Must use qmake, NOT cmake
assert_file_not_contains "[C5] Does NOT use cmake (Fulcrum requires qmake)" "${FUL}" "cmake"
assert_file_contains "[C5] Uses qmake6 for building" "${FUL}" "qmake6"
# Bug C5: Missing libbz2-dev
assert_file_contains "[C5] Has libbz2-dev dependency" "${FUL}" "libbz2-dev"

echo ""
echo "=================================="
echo "Results: ${TOTAL} tests, ${PASS} passed, ${FAIL} failed"
echo "=================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
