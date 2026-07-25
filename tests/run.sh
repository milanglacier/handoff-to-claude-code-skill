#!/usr/bin/env bash
# Runs every case in tests/cases. No dependencies beyond bash and coreutils.
#
#   bash tests/run.sh                 # offline only
#   HANDOFF_LIVE=1 bash tests/run.sh  # also run the live smoke test

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$TESTS_DIR/fake-claude" 2>/dev/null

failed_cases=0
total_cases=0

for case_file in "$TESTS_DIR"/cases/*.sh; do
    name="$(basename "$case_file" .sh)"
    total_cases=$((total_cases + 1))
    printf '%s\n' "$name"
    if bash "$case_file"; then
        :
    else
        printf '  -> %s assertion(s) failed\n' "$?"
        failed_cases=$((failed_cases + 1))
    fi
done

printf '\n'
if [ "$failed_cases" -eq 0 ]; then
    printf 'all %s case(s) passed\n' "$total_cases"
    exit 0
fi
printf '%s of %s case(s) failed\n' "$failed_cases" "$total_cases"
exit 1
