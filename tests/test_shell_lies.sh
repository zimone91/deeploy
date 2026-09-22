#!/usr/bin/env bash
# Ways the shell broke a CHECK rather than the thing being checked.
#
# Every case here cost something real in this repository: a red CI run, a false
# green, or an hour spent looking at innocent code. None of them was a defect in
# the subject. All of them were the tooling quietly answering a different
# question from the one asked.
#
# WHERE THE BOUNDARY RUNS, because the next person will try to put the wrong half
# in here. This file holds what is MECHANICAL: a behaviour of a shell or a tool
# that can be demonstrated in a few lines and controlled in both directions. It
# does not hold what is METHODICAL — a control that inherits its subject instead
# of receiving it, a check verified against a retyped model of itself, a search
# window that spills into the neighbouring call, a `git stash` that takes the
# test away with the code under test. Those are about how we verify, not about
# what the shell does, they cannot be turned into an assertion, and they live in
# CONTRIBUTING.md as rules.
#
# Three kinds live here, and the difference matters:
#
#   FACTS       — portable behaviour, asserted directly. If bash or coreutils
#                 ever change it, this goes red, which is the point.
#   ABSTENTIONS — behaviour that DIVERGES between implementations, and the
#                 principle that follows from it: assert what you measured and
#                 what you own. Someone else's sed is not ours — asserting how it
#                 behaves would be a claim about every box this might run on,
#                 made from the one box it ran on. This tree IS ours, so the
#                 assertion is that the tree does not depend on the divergent
#                 form. Same boundary as every gate here: the derivation reads
#                 the code in this repository and refuses to speak for what is
#                 outside it.
#   MEASURED    — behaviour of a tool that may be absent. Run where present, and
#                 SAY which branch ran. Never silently skipped: a case that
#                 quietly does not run is the defect this file exists for.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

echo "== FACTS: portable behaviour this repository depends on =="

# 1. $? after a pipeline, and the condition nobody states when repeating the
#    warning. WITHOUT pipefail it is the LAST element's status, so a failure
#    upstream vanishes — that is the form that misread a 126 as a 0, because an
#    ad-hoc command typed at a prompt has pipefail off. WITH pipefail, which is
#    what every script in this tree runs under, $? is the rightmost NON-ZERO
#    status and the failure does survive. Writing this file is what separated the
#    two: the first version of this very assertion expected 0 and got 42, because
#    the suite itself sets pipefail.
nopf=$( set +o pipefail; ( exit 42 ) | cat; echo $? )
withpf=$( set -o pipefail; ( exit 42 ) | cat; echo $? )
check "without pipefail \$? is the LAST element's"      "$nopf"  "0"
check "with pipefail \$? is the failing element's"      "$withpf" "42"
# PIPESTATUS answers regardless of pipefail, which is why it is the thing to
# reach for rather than remembering which mode you are in.
ps0=$( set +o pipefail; ( exit 42 ) | cat; echo "${PIPESTATUS[0]}" )
check "  PIPESTATUS[0] is the first element's either way" "$ps0" "42"
# Control the other way: without a pipe at all, $? is the command's own. Without
# this, the pair above would pass on a shell that always answered 0.
( exit 42 ); check "  and without a pipe \$? is the command's" "$?" "42"
# It is clobbered by the next command, which is why it must be read on the very
# next line and not two lines later.
( exit 42 ) | cat; : ; check "  PIPESTATUS is gone after one more command" "${PIPESTATUS[0]}" "0"

# 2. A tab is IFS whitespace, so `IFS=$'\t' read -r a b` STRIPS a leading one and
#    shifts the fields. This made an anchor-link derivation count zero links and
#    report the documentation as broken.
printf '\tsecond\n' > "$WORK/tabline"
IFS=$'\t' read -r f1 f2 < "$WORK/tabline"
check "leading tab is eaten by IFS-splitting read"      "[${f1}][${f2}]" "[second][]"
IFS= read -r whole < "$WORK/tabline"
check "  splitting by hand keeps the empty first field" "[${whole%%$'\t'*}][${whole#*$'\t'}]" "[][second]"

# 3. Extracting "every digit" from a URL-encoded string finds the encoding too.
#    %20 is a space and contains a 20: this made a badge gate compare a two-line
#    string against one number, and it went red on a badge that was correct.
badge='tests-22%20suites'
check "every-digit extraction returns TWO numbers"      "$(grep -oE '[0-9]+' <<<"$badge" | tr '\n' ' ')" "22 20 "
check "  extracting the field returns one"              "$(sed -n 's/.*tests-\([0-9][0-9]*\)%20suites.*/\1/p' <<<"$badge")" "22"

# 4. `git log --until=<bare date>` fills the time of day from NOW, read on the
#    reader's clock — and that is measured, not inferred.
#
#    It was filed under FACTS and CI took it apart on the first run: this box
#    answered 0, ubuntu-latest answered 1. The replacement assertion — "a bare
#    date is not timezone-invariant" — then failed too, on a tree byte-identical
#    to one that had just passed, because the property itself moves with the
#    clock. Two reconstructions of the cause were wrong and neither was written
#    down; a third was established against a controlled repository and holds.
#
#    Five commits at 00/06/12/18/23 UTC on 2026-05-31, one git binary, three
#    timezones, at 02:10 UTC on 2026-09-22. The boundary is "2026-05-31 at the
#    current local time of day", and predicting each count from that matched the
#    actual three times out of three:
#
#      TZ=UTC                 local 02:10 -> boundary 02:10+00:00 -> 1
#      TZ=Europe/Moscow       local 05:10 -> boundary 05:10+03:00 -> 1
#      TZ=America/Los_Angeles local 19:10 -> boundary 19:10-07:00 -> 5
#
#    So a bare date answers a different question every hour, and the same
#    question differently in each timezone. That cannot be asserted — a test of
#    it would go red at some hours and green at others, which is what it did.
#    What IS stable is the narrower hazard underneath: an explicit time with no
#    offset is still read on the reader's clock — and because every field of it
#    is given, nothing is filled from "now", so the answer holds whatever hour
#    the suite runs at. Four --until values against the same five commits, UTC
#    against Europe/Moscow: 00:30 -> 1 vs 0, 06:00 -> 2 vs 1, 12:00 -> 3 vs 2,
#    23:30 -> 5 vs 4. Four values of the argument, not four times of running.
#
#    The cure is to give the offset, and that is what gets asserted.
command -v git >/dev/null 2>&1 || {
    printf '  FAIL this case needs git and there is none — refusing to skip it\n'
    printf 'RESULT: %d passed, %d failed\n' "$PASS" "$((FAIL + 1))"; exit 1; }
cd "$WORK" && git init -q datebox && cd datebox || exit 1
for h in 00 06 12 18 23; do
    GIT_COMMITTER_DATE="2026-05-31T${h}:00:00+00:00" \
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "at${h}" \
        --date="2026-05-31T${h}:00:00+00:00"
done
utc_x=$(TZ=UTC           git log --until='2026-05-31T23:59:59+00:00' --oneline | wc -l | tr -d ' ')
msk_x=$(TZ=Europe/Moscow git log --until='2026-05-31T23:59:59+00:00' --oneline | wc -l | tr -d ' ')
check "an explicit time WITH an offset is timezone-invariant" "$utc_x" "$msk_x"
check "  and it finds every commit of that UTC day"           "$utc_x" "5"
# The stable half of the hazard: drop the offset and the reader's clock is back.
# Fixed times, so this does not move with the hour the suite happens to run.
utc_n=$(TZ=UTC           git log --until='2026-05-31T23:59:59' --oneline | wc -l | tr -d ' ')
msk_n=$(TZ=Europe/Moscow git log --until='2026-05-31T23:59:59' --oneline | wc -l | tr -d ' ')
check "an explicit time WITHOUT an offset is not"  "$([[ "$utc_n" != "$msk_n" ]] && echo differs || echo same)" "differs"
# Control: both timezones answered. Without it the line above would pass because
# one of the two queries returned nothing at all.
check "  and both timezones answered"              "$([[ -n "$utc_n" && -n "$msk_n" ]] && echo yes || echo no)" "yes"
cd "$ROOT" || exit 1

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
