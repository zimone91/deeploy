#!/usr/bin/env bash
# Phase 0 must assert every external command the install runs AFTER the point of
# no return, and that list must be DERIVED from the code rather than remembered.
#
# The defect this exists to prevent: mkfs.xfs was invoked one line after
# blkdiscard, came in no package DeePloy installs, and was checked nowhere. On a
# box without xfsprogs the run erased both data disks and then died on "command
# not found". A checklist entry would have been the same class of protection as
# the one that failed.
#
# This is a suite rather than a step in a workflow so that it runs wherever
# run_tests.sh runs, and so the controls below — six ways the gate must go red —
# run every time instead of once when someone remembered to try them.
#
# WHAT THIS GATE DOES NOT SEE, stated here because a check whose declared reach
# is wider than what it measures is the same defect it was built to catch.
#
# The derivation reads run/run_capture/run_redacted call sites. A command invoked
# directly — `awk -F= ...`, `x=$(lsblk -no NAME)`, `| sed 's/a/b/'` — is invisible
# to it. lib/keys.sh shows both halves on adjacent lines: :32 wraps `solana-keygen
# new` in run() and the gate sees it; :33 calls `solana-keygen pubkey` directly and
# the gate does not. mkfs.xfs was caught only because it happens to be written as
# `run mkfs.xfs`.
#
# Measured on this tree on 2026-09-20, by reading every occurrence — not assumed,
# and not a count of grep hits. 33 external commands are invoked directly in the
# 13 modules at or after the point of no return, after removing the ones this list
# or an earlier phase already covers (bash mkdir mv rm systemctl from the list
# itself; curl git jq from BASE_PACKAGES; cargo; and doublezero, which its own
# module apt-installs before calling it through "$@"):
#
#   awk basename blkid cat chmod cmp cp cut date df diff dirname find findmnt
#   grep head id ip lsblk mktemp mountpoint pgrep ping ps readlink sed sh sleep
#   sort stat sysctl taskset tr
#
# All 33 come from the Ubuntu 24.04 base system: coreutils, util-linux, procps,
# diffutils, findutils, grep, sed, mawk, dash, iproute2, iputils-ping. So no live
# defect hides here today. That is a fact about this tree on that date, not a
# property this gate enforces — the enforcement is the backlog item below.
#
# A second thing the derivation cannot see: executables invoked by PATH rather
# than by name. Four exist — "$SOLANA_BIN/solana" (doublezero.sh, start.sh,
# verify.sh), "$SOLANA_BIN/solana-keygen" (doublezero.sh, keys.sh, upgrade.sh),
# "$bin" for agave-xdp-compatibility (nic.sh) and ./scripts/cargo-install-all.sh
# (toolchain.sh). All four are artifacts DeePloy builds in an earlier phase, so
# they are not system dependencies — but they are just as invisible here, and one
# that failed to build would surface as the same "not found" after the wipe.
#
# Not counted, deliberately: commands that appear only inside heredoc bodies of
# scripts this repo GENERATES — logger throughout nic.sh, and validatorcfg.sh's
# own ps, taskset and solana, which sit in a placeholder-substituted body written
# to disk. systemd runs those later, which is a different subject from what the
# install itself needs before it erases the disks.
#
# Backlog — DIRECT-CALL-SET: a second assertion, that the set of directly invoked
# externals equals a recorded set of exceptions, so a direct call to something
# non-base goes red. Same shape as the version-literal gate: set equality, not
# containment. Not done here because deriving direct calls is noisy — a heuristic
# pass over this tree produced ~170 false positives, among them `bc`, which is an
# awk variable in lib/doublezero.sh:431, not the calculator.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

# ---------------------------------------------------------------------------
# The gate itself, against an arbitrary tree so the controls can craft one.
# Prints a reason and returns 1 on every refusal; prints a summary and returns 0
# when the asserted set and the derived set agree.
# ---------------------------------------------------------------------------
tool_gate() {                              # <tree>
    local t="$1" m p fn n nor_mod pkg_mod nor pkg mods
    _phase_of() {                          # <lib/x.sh>
        local mm="$1"
        while read -r n fn; do
            grep -qE "^${fn}\(\)" "$mm" && { echo "$n"; return 0; }
        done < <(sed -n '/^run_phase()/,/^}/p' "$t/deeploy.sh" \
                 | grep -oE '^[[:space:]]*[0-9]\) [a-z_]+' | sed 's/)//' | awk '{print $1, $2}')
        return 1
    }
    # Both anchors are INVOCATIONS, never prose: a comment that merely mentions
    # blkdiscard must not be able to move the point of no return. One already
    # tried — the comment that documents this list.
    nor_mod=$(grep -lE '^[[:space:]]*run(_capture|_redacted)? blkdiscard' "$t"/lib/*.sh || true)
    pkg_mod=$(grep -lE '^[[:space:]]*run apt-get install -y "\$\{BASE_PACKAGES' "$t"/lib/*.sh || true)
    [[ -n "$nor_mod" && -n "$pkg_mod" ]] || { echo "could not locate the point of no return or the packages phase"; return 1; }
    nor=$(_phase_of "$nor_mod") || { echo "no phase maps to ${nor_mod##*/}"; return 1; }
    pkg=$(_phase_of "$pkg_mod") || { echo "no phase maps to ${pkg_mod##*/}"; return 1; }

    # Asserted, not assumed. Subtracting the phase-1 packages is only sound while
    # phase 1 runs before the wipe; if that ever changes, this list quietly stops
    # being right and nothing else would notice.
    if [[ "$pkg" -ge "$nor" ]]; then
        echo "packages install in phase ${pkg}, disks are erased in phase ${nor} — the subtraction is no longer sound"
        return 1
    fi

    # Every module at or after the point of no return. A module with no phase of
    # its own is included: it is reachable from one, and guessing which is how a
    # gate stops being one.
    mods=""
    for m in "$t"/lib/*.sh; do
        p=$(_phase_of "$m") || p=""
        if [[ -z "$p" || "$p" -ge "$nor" ]]; then mods="$mods $m"; fi
    done
    [[ -n "$mods" ]] || { echo "no modules resolved at or after phase ${nor}"; return 1; }

    # shellcheck disable=SC2086
    grep -hoE '^[[:space:]]*run(_capture|_redacted)? [a-zA-Z0-9_./-]+' $mods \
        | awk '{print $2}' | grep -v '^-' | sort -u > "$WORK/derived"
    sed -n '/^BASE_PACKAGES=(/,/^)/p' "$t/lib/base.sh" | tr ' ' '\n' \
        | grep -oE '^[a-z0-9][a-z0-9.+-]*$' | sort -u > "$WORK/sub"
    grep -oE 'apt-get install -y [a-z0-9 -]+' "$t/lib/doublezero.sh" | tr ' ' '\n' \
        | grep -E '^doublezero' >> "$WORK/sub"
    # Bounded to the array's OWN line. This was a sed range ending at /)/, and a
    # range's end is searched from the line AFTER the start, so it never ends on
    # the start line: it always read at least one line too many. That was
    # harmless only while the extra line began with '_' and the filter below
    # dropped it. Add a second array under this one and the range swallows it
    # whole — measured 2026-09-23, when PF_TOOLS_BASE_INSTALLED was added and its
    # four tools were silently subtracted from what the gate requires, turning a
    # real assertion into an empty one.
    local selfline
    selfline=$(grep -m1 '^PF_TOOLS_SELF_INSTALLED=(' "$t/lib/preflight.sh")
    [[ "$selfline" == *')'* ]] || {
        echo "PF_TOOLS_SELF_INSTALLED does not close on its own line — cannot bound it"; return 1; }
    printf '%s\n' "$selfline" \
        | tr ' ()' '\n' | grep -oE '^[a-z][a-z0-9.-]*$' | grep -v PF_TOOLS >> "$WORK/sub"
    sort -u "$WORK/sub" -o "$WORK/sub"
    comm -23 "$WORK/derived" "$WORK/sub" > "$WORK/want"

    sed -n '/^PF_REQUIRED_TOOLS=(/,/^)/p' "$t/lib/preflight.sh" \
        | tr ' ()' '\n' | grep -oE '^[a-z][a-zA-Z0-9.+_-]*$' | grep -v '^PF_REQUIRED' | sort -u > "$WORK/have"
    [[ -s "$WORK/want" ]] || { echo "derived an empty tool set — the derivation broke, not the code"; return 1; }
    [[ -s "$WORK/have" ]] || { echo "could not parse PF_REQUIRED_TOOLS out of lib/preflight.sh"; return 1; }

    if ! diff -q "$WORK/have" "$WORK/want" >/dev/null; then
        echo "PF_REQUIRED_TOOLS does not match what runs after the point of no return:"
        diff "$WORK/have" "$WORK/want" | sed 's/^/    /'
        return 1
    fi
    echo "phase ${pkg} installs packages, phase ${nor} erases disks; $(wc -l < "$WORK/want" | tr -d ' ') commands asserted"
    return 0
}

echo "== the tree as it stands =="
OUT=$(tool_gate "$ROOT"); RC=$?
check "gate passes"                       "$RC" "0"
check "  and says which phases it resolved" "$(grep -c 'installs packages' <<<"$OUT")" "1"

# --- the controls ----------------------------------------------------------
# A gate that can only ever go green is not a gate. Each of these breaks the
# tree in one specific way and asserts BOTH the refusal and its reason: a
# refusal for the wrong reason is the failure mode this repo keeps meeting.
craft() {                                  # <name> -> prints the tree path
    local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"
    cp "$ROOT/deeploy.sh" "$d/"; cp -R "$ROOT/lib" "$d/"
    echo "$d"
}
control() {                                # <desc> <tree> <expected substring>
    local out rc
    out=$(tool_gate "$2" 2>&1); rc=$?
    check "$1 -> refused"      "$rc" "1"
    check "  for the stated reason" "$(grep -c "$3" <<<"$out")" "1"
}

echo "== controls: six ways it must go red =="
D=$(craft newtool)
awk '{print} /run mkfs.xfs -f/ && !d {print "        run cryptsetup luksFormat \"$d\""; d=1}' \
    "$ROOT/lib/disk.sh" > "$D/lib/disk.sh"
control "a command used after the wipe and asserted nowhere" "$D" "does not match what runs after"

D=$(craft stale)
sed 's/^    mount mv rm setcap swapoff systemctl$/    mount mv rm setcap swapoff systemctl zfs/' \
    "$ROOT/lib/preflight.sh" > "$D/lib/preflight.sh"
control "a command asserted that the code never runs" "$D" "does not match what runs after"

D=$(craft order)
sed -e 's/^        1) base_run ;;/        1) XbaseX ;;/' -e 's/^        3) disk_run ;;/        3) base_run ;;/' \
    -e 's/^        1) XbaseX ;;/        1) disk_run ;;/' "$ROOT/deeploy.sh" > "$D/deeploy.sh"
control "packages moved after the wipe" "$D" "the subtraction is no longer sound"

D=$(craft anchor)
sed 's/run blkdiscard -f/run discard_it -f/' "$ROOT/lib/disk.sh" > "$D/lib/disk.sh"
control "nothing runs blkdiscard any more" "$D" "could not locate the point of no return"

D=$(craft unparseable)
sed 's/^PF_REQUIRED_TOOLS=(/PF_REQUIRED_TOOLS="/' "$ROOT/lib/preflight.sh" > "$D/lib/preflight.sh"
control "PF_REQUIRED_TOOLS cannot be parsed" "$D" "could not parse PF_REQUIRED_TOOLS"

D=$(craft phasemap)
sed 's/^run_phase() {/run_phase_renamed() {/' "$ROOT/deeploy.sh" > "$D/deeploy.sh"
control "the phase map cannot be read" "$D" "no phase maps to"

# The subtraction reads one named array. Anything written next to it must not be
# read as part of it — the parser used to take the neighbour whole, which is the
# window-spills-into-the-neighbour defect from CONTRIBUTING, sitting inside a gate.
echo "== a neighbouring array is not absorbed into the subtraction =="
D=$(craft neighbour)
awk '{print}
     /^PF_TOOLS_SELF_INSTALLED=\(/ && !d {
        print ""
        print "# planted by tests/test_toolgate.sh"
        print "PF_TOOLS_PLANTED=(getcap mdadm mkfs.xfs setcap)"
        d=1 }' "$ROOT/lib/preflight.sh" > "$D/lib/preflight.sh"
check "the plant really landed next to it" \
      "$(grep -c '^PF_TOOLS_PLANTED=(' "$D/lib/preflight.sh")" "1"
OUT=$(tool_gate "$D" 2>&1); RC=$?
check "  and the gate still passes"        "$RC" "0"
check "  and still resolves both phases"   "$(grep -c 'installs packages' <<<"$OUT")" "1"

D=$(craft multiline)
printf '%s\n' 'PF_TOOLS_SELF_INSTALLED=(' '    cargo rustup' ')' > "$WORK/ml"
awk 'BEGIN{while((getline l < ARGV[2])>0) m[++n]=l; ARGV[2]=""}
     /^PF_TOOLS_SELF_INSTALLED=\(/ {for(i=1;i<=n;i++) print m[i]; next} {print}' \
    "$ROOT/lib/preflight.sh" "$WORK/ml" > "$D/lib/preflight.sh"
control "PF_TOOLS_SELF_INSTALLED spread over lines" "$D" "cannot bound it"

# A comment is not an invocation: the block documenting PF_REQUIRED_TOOLS names
# blkdiscard in prose, and that must not be able to relocate the wipe.
echo "== prose cannot move the point of no return =="
check "preflight.sh mentions blkdiscard in prose" \
      "$(grep -c 'blkdiscard' "$ROOT/lib/preflight.sh" | awk '{print ($1>0)?1:0}')" "1"
OUT=$(tool_gate "$ROOT"); check "and the gate still resolves phase 3" "$(grep -c 'erases disks' <<<"$OUT")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
