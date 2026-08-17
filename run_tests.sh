#!/usr/bin/env bash
# ============================================================================
# DeePloy — test runner
#
# Runs the suites and fails LOUDLY. This exists because the obvious one-liner
#   for t in tests/test_*.sh; do bash "$t"; done
# lies twice: the loop's own exit status is that of the LAST suite (so an
# earlier failure disappears), and a suite that dies mid-run — an unexpected
# `fail`, a syntax error, a killed process — prints no RESULT line at all, so
# any tally built by reading RESULT lines counts it as zero failures.
#
# So: a suite counts as passing only if it BOTH exits 0 AND prints its RESULT
# line with 0 failures. Anything else is a failure, including silence.
#
# Usage:  ./run_tests.sh                 # every suite
#         ./run_tests.sh tests/test_x.sh # just these
# Exit:   0 = all suites passed; 1 = anything failed, died, or stayed silent.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || { echo "cannot cd to ${HERE}" >&2; exit 1; }

suites=("$@")
if [[ ${#suites[@]} -eq 0 ]]; then
    suites=(tests/test_*.sh)
    [[ -e "${suites[0]}" ]] || { echo "no suites found under tests/" >&2; exit 1; }
fi

pass_total=0
fail_total=0
bad_suites=0
rc=0

for t in ${suites[@]+"${suites[@]}"}; do
    name="$(basename "$t")"
    out="$(bash "$t" 2>&1)"
    suite_rc=$?
    line="$(printf '%s\n' "$out" | grep -E '^RESULT: [0-9]+ passed, [0-9]+ failed' | tail -1)"

    if [[ -z "$line" ]]; then
        # No RESULT: the suite never reached its own summary. This is the case
        # a RESULT-only tally reports as "0 failed".
        printf '  %-26s DIED (exit %s, no RESULT line)\n' "$name" "$suite_rc"
        printf '%s\n' "$out" | tail -15 | sed 's/^/      | /'
        bad_suites=$((bad_suites + 1)); rc=1
        continue
    fi

    p="$(printf '%s' "$line" | sed -E 's/RESULT: ([0-9]+) passed.*/\1/')"
    f="$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failed.*/\1/')"
    pass_total=$((pass_total + p))
    fail_total=$((fail_total + f))

    if [[ "$suite_rc" -ne 0 || "$f" -ne 0 ]]; then
        printf '  %-26s FAIL  %s passed, %s failed (exit %s)\n' "$name" "$p" "$f" "$suite_rc"
        printf '%s\n' "$out" | grep -E '^  FAIL' -A3 | sed 's/^/      | /'
        bad_suites=$((bad_suites + 1)); rc=1
    else
        printf '  %-26s ok    %s passed\n' "$name" "$p"
    fi
done

echo
if [[ "$rc" -eq 0 ]]; then
    printf 'ALL GREEN — %s suites, %s assertions passed\n' "${#suites[@]}" "$pass_total"
else
    printf 'FAILED — %s of %s suites bad; %s assertions passed, %s failed\n' \
        "$bad_suites" "${#suites[@]}" "$pass_total" "$fail_total"
fi
exit "$rc"
