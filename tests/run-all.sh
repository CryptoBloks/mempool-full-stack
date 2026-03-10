#!/usr/bin/env bash
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${PROJECT_ROOT}/tests"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_NAMES=()

run_suite() {
    local name="$1"
    local script="$2"

    ((TOTAL_SUITES++)) || true

    echo ""
    echo "================================================================"
    echo "  Running: ${name}"
    echo "================================================================"
    echo ""

    if bash "${script}"; then
        ((PASSED_SUITES++)) || true
        printf '\n  \033[0;32mSUITE PASSED: %s\033[0m\n' "${name}"
    else
        ((FAILED_SUITES++)) || true
        FAILED_NAMES+=("${name}")
        printf '\n  \033[0;31mSUITE FAILED: %s\033[0m\n' "${name}"
    fi
}

echo ""
echo "================================================================"
echo "  mempool.space full-stack-docker — Test Suite"
echo "================================================================"

# Suite 1: shellcheck (only if shellcheck is installed)
if command -v shellcheck &>/dev/null; then
    run_suite "shellcheck" "${TESTS_DIR}/shellcheck.sh"
else
    echo ""
    echo "  [SKIP] shellcheck not installed (apt install shellcheck)"
    ((TOTAL_SUITES++)) || true
fi

# Suite 2: Config pipeline tests
run_suite "config-pipeline" "${TESTS_DIR}/test-config-pipeline.sh"

# Suite 3: Dockerfile validation
run_suite "dockerfiles" "${TESTS_DIR}/test-dockerfiles.sh"

# Summary
echo ""
echo "================================================================"
echo "  Final Results"
echo "================================================================"
echo ""
echo "  Suites run:    ${TOTAL_SUITES}"
echo "  Suites passed: ${PASSED_SUITES}"
echo "  Suites failed: ${FAILED_SUITES}"

if [[ ${FAILED_SUITES} -gt 0 ]]; then
    echo ""
    echo "  Failed suites:"
    for name in "${FAILED_NAMES[@]}"; do
        printf '    \033[0;31m✗\033[0m %s\n' "${name}"
    done
    echo ""
    exit 1
fi

echo ""
printf '  \033[0;32mAll suites passed.\033[0m\n'
echo ""
exit 0
