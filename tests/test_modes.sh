#!/usr/bin/env bash
# The executable bit is part of what ships, and nothing here used to check it.
#
# `git archive` packs tracked files and preserves INDEX modes, so a deeploy.sh
# recorded 100644 unpacks non-executable from the release tarball and the
# README's own first command, ./deeploy.sh, fails. v0.1.0-rc6 shipped exactly
# that.
#
# The failed command is the mild half. install writes a systemd unit whose
# ExecStart is that same path, and `systemctl enable` does not look at the bit —
# so the real failure lands at boot, as status=203/EXEC, after the reboot, on a
# box whose disks were erased three phases earlier.
#
# Two ways to measure, because the file is consumed in two places and both are
# real: inside a checkout the INDEX mode is what git archive will write; inside
# an unpacked tarball there is no index and the filesystem mode IS the shipped
# mode. Neither branch is a skip, and the suite says which one it used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

# Both helpers take a root so the controls further down can craft a tree and ask
# the same questions of it. A crafted tree is not a repository, which is exactly
# the unpacked-tarball case the second branch already exists for.
mode_in() {                                       # <root> <path>
    if git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$1" ls-files -s -- "$2" | awk '{print substr($1,4)}'
    else
        stat -c %a "$1/$2" 2>/dev/null || stat -f %Lp "$1/$2" 2>/dev/null
    fi
}
source_of() {                                     # <root> -> "git index" | "unpacked files"
    if git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
    then echo "git index"; else echo "unpacked files"; fi
}
mode_of() { mode_in "$ROOT" "$1"; }
SOURCE=$(source_of "$ROOT")
echo "== modes, measured from the ${SOURCE} =="

# Prove the measurement works before reporting on it. A mode_of that returned
# nothing would make every "is not executable" assertion below pass.
check "the measurement produces a mode at all" "$(mode_of deeploy.sh | grep -cE '^[0-7]{3,4}$')" "1"

# "unmeasured" rather than "no" when the mode cannot be read: the controls below
# expect "no", and an untracked or missing file would otherwise satisfy them
# without anything having been measured.
x_bit() {
    local m; m=$(mode_of "$1")
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || { echo "unmeasured"; return 0; }
    if (( (8#$m & 0111) != 0 )); then echo yes; else echo no; fi
}

# The entry point. Documented as ./deeploy.sh in README and used verbatim as the
# resume unit's ExecStart.
check "deeploy.sh is executable"   "$(x_bit deeploy.sh)"   "yes"
# Documented as ./run_tests.sh in CONTRIBUTING; it was already 755 and must stay.
check "run_tests.sh is executable" "$(x_bit run_tests.sh)" "yes"

# Controls, the other way. Without these, a check that called everything
# executable would pass both assertions above. lib/*.sh are SOURCED, never run,
# and the config example is data.
check "lib/common.sh is NOT executable"       "$(x_bit lib/common.sh)"       "no"
check "lib/disk.sh is NOT executable"         "$(x_bit lib/disk.sh)"         "no"
check "deeploy.conf.example is NOT executable" "$(x_bit deeploy.conf.example)" "no"
check "README.md is NOT executable"           "$(x_bit README.md)"           "no"
# And the predicate must be able to SAY it measured nothing, so that "no" above
# means a mode was read and had no x bit — not that the file was absent.
check "a path that is not there reads as unmeasured" "$(x_bit no/such/file.sh)" "unmeasured"

# ---------------------------------------------------------------------------
# Gate A: a script this repository tells a reader to run as ./x.sh must be
# executable. Derived from the documentation rather than from a list here, so a
# newly documented script arrives checked instead of remembered.
#
# CHANGELOG.md is excluded ON PURPOSE, and the exclusion is asserted below rather
# than left as a quiet narrowing. The changelog records what was true at a past
# release — CHANGELOG.md:328 names ./deeploy.sh while describing a fix from an
# earlier version. Holding history to the present tree would make history
# unwritable. Every other tracked .md is an instruction to someone reading now.
# ---------------------------------------------------------------------------
docs_of() {                                       # <root> -> doc paths, changelog excluded
    if git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$1" ls-files '*.md'
    else
        ( cd "$1" && find . -name '*.md' -type f | sed 's|^\./||' )
    fi | grep -v '^CHANGELOG\.md$'
}

gate_a() {                                        # <root> -> 0 and a summary, or 1 and a reason
    local root="$1" f s n=0 scripts missing="" nox=""
    scripts=$(docs_of "$root" | while IFS= read -r f; do
                  grep -hoE '\./[A-Za-z0-9_][A-Za-z0-9_.-]*\.sh' "$root/$f" 2>/dev/null
              done | sed 's|^\./||' | sort -u)
    [[ -n "$scripts" ]] || { echo "derived no documented scripts at all — the derivation broke, not the docs"; return 1; }
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        n=$((n + 1))
        if [[ ! -f "$root/$s" ]]; then missing="$missing $s"; continue; fi
        local m; m=$(mode_in "$root" "$s")
        [[ "$m" =~ ^[0-7]{3,4}$ ]] || { echo "could not read a mode for documented script ${s}"; return 1; }
        (( (8#$m & 0111) != 0 )) || nox="$nox $s"
    done <<<"$scripts"
    [[ -z "$missing" ]] || { echo "documented as ./x.sh but not in the tree:${missing}"; return 1; }
    [[ -z "$nox" ]] || { echo "documented as ./x.sh but not executable:${nox} — a reader who types it gets Permission denied"; return 1; }
    echo "${n} documented script(s) checked, all executable"
    return 0
}

echo "== Gate A: every documented ./x.sh is executable =="
OUT=$(gate_a "$ROOT"); RC=$?
check "gate passes on this tree"        "$RC" "0"
check "  and it checked more than zero" "$(grep -cE '^[1-9][0-9]* documented' <<<"$OUT")" "1"

craft() {                                         # <name> -> a tree that is NOT a repository
    local d="$WORKDIR/$1"; rm -rf "$d"; mkdir -p "$d"
    tar -cf - --exclude .git -C "$ROOT" . 2>/dev/null | tar -xf - -C "$d"
    echo "$d"
}
control() {                                       # <desc> <tree> <expected substring>
    local out rc; out=$(gate_a "$2" 2>&1); rc=$?
    check "$1 -> refused"           "$rc" "1"
    check "  for the stated reason" "$(grep -c "$3" <<<"$out")" "1"
}
WORKDIR=$(mktemp -d); trap 'rm -rf "$WORKDIR"' EXIT

D=$(craft newdoc)
# shellcheck disable=SC2016  # backticks are markdown here, not substitution
printf 'Run `./helper.sh` to do the thing.\n' >"$D/docs/HELPER.md"
printf '#!/bin/bash\n' >"$D/helper.sh"; chmod 644 "$D/helper.sh"
control "a newly documented script with no +x" "$D" "not executable: helper.sh"

D=$(craft gone)
rm -f "$D/run_tests.sh"
control "a documented script that is not in the tree" "$D" "not in the tree"

D=$(craft nodocs)
find "$D" -name '*.md' -delete
control "no documentation at all" "$D" "derived no documented scripts"

# CONTRIBUTING.md must be IN the source of truth. run_tests.sh is named in two
# places, so removing the other one leaves CONTRIBUTING as the only mention: a
# gate that skipped it would go green here.
D=$(craft contributing_only)
# shellcheck disable=SC2016  # ditto: markdown backticks in the pattern
sed -i.bak 's|`./run_tests.sh`|the test runner|' "$D/.github/pull_request_template.md" && rm -f "$D"/.github/*.bak
chmod 644 "$D/run_tests.sh"
control "run_tests.sh named only by CONTRIBUTING, bit dropped" "$D" "not executable: run_tests.sh"
# Control the other way: the same tree with the bit intact must pass, so the red
# above came from the mode and not from the edit that isolated the mention.
chmod 755 "$D/run_tests.sh"
gate_a "$D" >/dev/null; check "  and with the bit back it passes" "$?" "0"

# The changelog exclusion is deliberate, so assert it. A tree where ONLY the
# changelog names a script that does not exist must stay green; if the exclusion
# were ever dropped, history would start failing the build.
D=$(craft changelog_only)
# shellcheck disable=SC2016  # markdown backticks again
printf '\n- Old note mentioning `./retired-thing.sh`, removed in a later release.\n' >>"$D/CHANGELOG.md"
gate_a "$D" >/dev/null; RC3=$?
check "a script named only in CHANGELOG is ignored" "$RC3" "0"
check "  and the changelog really does name it" \
      "$(grep -c 'retired-thing.sh' "$D/CHANGELOG.md")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
