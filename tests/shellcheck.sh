#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Check that shellcheck is installed
if ! command -v shellcheck &>/dev/null; then
    echo "ERROR: shellcheck is not installed."
    echo "Install it with:"
    echo "  Ubuntu/Debian: sudo apt install shellcheck"
    echo "  macOS:         brew install shellcheck"
    echo "  Arch:          sudo pacman -S shellcheck"
    exit 1
fi

# Collect all .sh files under scripts/ and tests/
mapfile -t files < <(find "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/tests" -name '*.sh' -type f | sort)

passed=0
failed=0

for file in "${files[@]}"; do
    rel="${file#"$PROJECT_ROOT/"}"
    if shellcheck \
        -e SC1091 \
        -e SC2034 \
        -e SC1090 \
        -S warning \
        "$file"; then
        echo "PASS: $rel"
        ((passed++))
    else
        echo "FAIL: $rel"
        ((failed++))
    fi
done

total=$((passed + failed))
echo ""
echo "$total files checked, $passed passed, $failed failed"

if ((failed > 0)); then
    exit 1
fi

exit 0
