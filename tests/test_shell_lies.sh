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

# 4. `git log --until=<bare date>` — and the reason this one is NOT a fact.
#
#    It was filed under FACTS and CI took it apart on the first run: this box
#    answered 0, ubuntu-latest answered 1, same query, same repository. Measured
#    on 2026-09-22 with one git binary and only TZ changed, against commits made
#    across 2026-05-31 UTC:
#
#      TZ=UTC              --until=2026-05-31 behaves as END of day   (== 23:59:59)
#      TZ=Europe/Moscow    --until=2026-05-31 behaves as START of day (== 00:00:00)
#
#    Two readings of the same string, decided by the reader's timezone. No
#    mechanism is claimed here, because none was established — twice in this batch
#    a mechanism was asserted that had not been measured, and a wrong cause sends
#    the next person somewhere there is nothing to find. What IS established is
#    that the bare form is not a question with one answer.
#
#    So what gets asserted is the cure, and it is portable: give the time AND the
#    offset, and the answer stops depending on who is asking.
cd "$WORK" && git init -q datebox && cd datebox || exit 1
for h in 00 03 12 21; do
    GIT_COMMITTER_DATE="2026-05-31T${h}:00:00+00:00" \
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "at${h}" \
        --date="2026-05-31T${h}:00:00+00:00"
done
utc_x=$(TZ=UTC            git log --until='2026-05-31T23:59:59+00:00' --oneline | wc -l | tr -d ' ')
msk_x=$(TZ=Europe/Moscow  git log --until='2026-05-31T23:59:59+00:00' --oneline | wc -l | tr -d ' ')
check "an explicit timestamp WITH an offset is timezone-invariant" "$utc_x" "$msk_x"
check "  and it finds the day's commits"                           "$utc_x" "4"
# The hazard itself, asserted so that its disappearance is also news: the bare
# form is NOT invariant. If a future git makes it so, this goes red and someone
# re-reads the comment above, which is the right outcome either way.
utc_b=$(TZ=UTC            git log --until=2026-05-31 --oneline | wc -l | tr -d ' ')
msk_b=$(TZ=Europe/Moscow  git log --until=2026-05-31 --oneline | wc -l | tr -d ' ')
check "a bare date is NOT timezone-invariant"  "$([[ "$utc_b" != "$msk_b" ]] && echo differs || echo same)" "differs"
# Control the other way: the two timezones are genuinely both in play, so the
# assertion above cannot pass because one of the queries returned nothing at all.
check "  and both timezones answered"          "$([[ -n "$utc_b" && -n "$msk_b" ]] && echo yes || echo no)" "yes"
cd "$ROOT" || exit 1

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
