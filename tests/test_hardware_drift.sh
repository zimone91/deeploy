#!/usr/bin/env bash
# hardware-drift.sh — the line the release notes carry instead of a sentence
# somebody typed. Two things have to hold: the number is DERIVED, and the two
# ways it can fail to answer are told apart.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
DRIFT="$ROOT/hardware-drift.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

command -v git >/dev/null 2>&1 || {
    printf '  FAIL this suite needs git and there is none — refusing to skip it\n'
    printf 'RESULT: %d passed, %d failed\n' "$PASS" "$((FAIL+1))"; exit 1; }
[[ -x "$DRIFT" ]] || {
    printf '  FAIL hardware-drift.sh is missing or not executable\n'
    printf 'RESULT: %d passed, %d failed\n' "$PASS" "$((FAIL+1))"; exit 1; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    printf '  ok   not a git work tree here — the measured cases cannot run\n'
    printf '  FAIL and this suite will not pretend they passed\n'
    printf 'RESULT: %d passed, %d failed\n' "$((PASS+1))" "$((FAIL+1))"; exit 1; }

echo "== the line it prints is derived, not typed =="
OUT=$(cd "$ROOT" && "$DRIFT" 2>&1); RC=$?
check "it measures this tree"              "$RC" "0"
check "  and says 'files changed'"         "$(grep -c 'files changed' <<<"$OUT")" "1"

# Derived: recompute the same statistic here and require the line to carry it.
# Without this the case above passes on a script that prints a fixed sentence.
# shellcheck disable=SC2016  # the literal ${HW_ANCHOR:-...} IS the thing being
# matched in the source file; expanding it here would search for its value.
ANCHOR=$(cd "$ROOT" && sed -n 's/^HW_ANCHOR="\${HW_ANCHOR:-\([0-9a-f]*\)}"$/\1/p' hardware-drift.sh)
check "the anchor is readable from one place" "$(printf '%s' "$ANCHOR" | grep -cE '^[0-9a-f]{7,40}$')" "1"
WANT=$(cd "$ROOT" && git diff --shortstat "$ANCHOR" HEAD -- deeploy.sh lib/ | sed 's/^ *//')
check "  and the printed numbers are that measurement" "$(grep -c -- "$WANT" <<<"$OUT")" "1"
# Control on the control: the recomputation is not vacuous.
check "  control: the recomputation found something" "$(grep -c 'files changed' <<<"$WANT")" "1"

# The reader has to see WHAT the drift is measured from, or the number is a
# number about nothing.
SUBJ=$(cd "$ROOT" && git log -1 --format=%s "$ANCHOR")
DATE=$(cd "$ROOT" && git log -1 --format=%ad --date=short "$ANCHOR")
check "it names the anchor's subject"      "$(grep -cF "$SUBJ" <<<"$OUT")" "1"
check "it names the anchor's date"         "$(grep -cF "$DATE" <<<"$OUT")" "1"

echo "== a ref can be asked for explicitly =="
TAGOUT=$(cd "$ROOT" && "$DRIFT" v0.1.0-rc7 2>&1); TRC=$?
check "a tag is accepted"                  "$TRC" "0"
TAGWANT=$(cd "$ROOT" && git diff --shortstat "$ANCHOR" v0.1.0-rc7 -- deeploy.sh lib/ | sed 's/^ *//')
check "  and answers about THAT ref"       "$(grep -c -- "$TAGWANT" <<<"$TAGOUT")" "1"
check "  which differs from HEAD's answer" "$([[ "$TAGWANT" != "$WANT" ]] && echo differs || echo same)" "differs"
BADREF=$(cd "$ROOT" && "$DRIFT" no-such-ref 2>&1); check "an unresolvable ref -> cannot measure" "$?" "2"
check "  and says which ref"               "$(grep -c 'no-such-ref' <<<"$BADREF")" "1"

echo "== the two failures are NOT the same failure =="
# CONTRIBUTING rule 3. A depth-1 checkout cannot reach the anchor, and asking
# whether the anchor exists answers the same "no" a rewritten history would.
# CI checks out depth 1 by default, so this is the ORDINARY case on a runner.
GONE=$(cd "$ROOT" && HW_ANCHOR=deadbee "$DRIFT" 2>&1); GRC=$?
check "an anchor this history lacks -> failure" "$GRC" "1"
check "  and it says so"                   "$(grep -c 'not in this history' <<<"$GONE")" "1"
check "  and does NOT blame the clone"     "$(grep -c 'shallow' <<<"$GONE")" "0"

git clone --quiet --depth 1 "file://$ROOT" "$WORK/shallow" 2>/dev/null
check "control: the shallow fixture really is shallow" \
      "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository 2>/dev/null)" "true"
cp "$DRIFT" "$WORK/shallow/hardware-drift.sh"
SHAL=$(cd "$WORK/shallow" && ./hardware-drift.sh 2>&1); SRC=$?
check "a shallow clone -> cannot measure"  "$SRC" "2"
check "  and names the cause"              "$(grep -c 'shallow clone' <<<"$SHAL")" "1"
check "  and names the cure"               "$(grep -c 'fetch-depth: 0' <<<"$SHAL")" "1"
check "  and refuses to call it missing"   "$(grep -c 'not in this history' <<<"$SHAL")" "0"
check "the two exit codes differ"          "$([[ "$GRC" != "$SRC" ]] && echo differs || echo same)" "differs"

echo "== and CI must not be the shallow case =="
# Measured, not assumed: every checkout that later needs the history has to ask
# for it. This is the assertion that would have caught the green-here-red-there.
for wf in .github/workflows/ci.yml .github/workflows/release.yml; do
    n=$(grep -c 'actions/checkout' "$ROOT/$wf")
    d=$(grep -c 'fetch-depth: 0' "$ROOT/$wf")
    check "$(basename "$wf"): every checkout asks for the full history" "$d" "$n"
done

echo "== and the lint list is derived, not typed =="
# hardware-drift.sh was invisible to CI on the day it was added: the lint step
# named deeploy.sh, get-deeploy.sh, run_tests.sh, lib/*.sh and tests/*.sh, and a
# new file at the top level matched none of them. A hand-maintained list of what
# to check is the same defect as a hand-maintained count of what was checked.
for wf in .github/workflows/ci.yml .github/workflows/release.yml; do
    # The step's NAME also contains "shellcheck -x", and matching it instead of
    # the command would assert about a label. Take the line that runs something.
    for what in 'shellcheck -x' 'bash -n'; do
        # The step's NAME also contains the command, and matching it instead of
        # the command would assert about a label. Take a line that runs something.
        line=$(grep -h -- "$what" "$ROOT/$wf" | grep -v '^ *#' | grep -v 'name:' | head -1)
        check "$(basename "$wf"): the '$what' step was found" \
              "$([[ -n "$line" ]] && echo found || echo missing)" "found"
        check "  and it enumerates from git, not by hand" \
              "$(grep -c 'git ls-files' <<<"$line")" "1"
    done
done

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
