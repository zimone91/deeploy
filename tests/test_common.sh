#!/usr/bin/env bash
# Self-contained tests for lib/common.sh — no root, no network, no live node.
# Runs every public helper against temp dirs and asserts behavior.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Sandbox: redirect all of DeePloy's writable locations into a temp tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state"
export DEEPLOY_BACKUP_DIR="$WORK/backups"
export DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1          # never block on stdin
export DEEPLOY_COLOR=never       # plain output for greppable assertions

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"

PASS=0; FAIL=0
check() { # check <desc> <actual> <expected>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi
}
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s (expr false: %s)\n' "$1" "$2"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s (expr true: %s)\n' "$1" "$2"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init

echo "== ensure_line =="
F="$WORK/sysctl.conf"
ensure_line "$F" "vm.swappiness=0"
ensure_line "$F" "vm.swappiness=0"   # idempotent
ensure_line "$F" "fs.nr_open=2000000"
check "append once (no dup)" "$(grep -c 'vm.swappiness=0' "$F")" "1"
check "second distinct line present" "$(grep -c 'fs.nr_open=2000000' "$F")" "1"

echo "== ensure_line key-replace =="
ensure_line "$F" "vm.swappiness=10" "^vm\.swappiness="
check "value replaced in place" "$(grep -E '^vm\.swappiness=' "$F")" "vm.swappiness=10"
check "still single swappiness line" "$(grep -c '^vm.swappiness' "$F")" "1"

echo "== ensure_kv =="
S="$WORK/system.conf"
ensure_kv "$S" "DefaultLimitNOFILE" "2000000"
ensure_kv "$S" "DefaultLimitNOFILE" "2000000"  # idempotent
check "kv present once" "$(grep -c 'DefaultLimitNOFILE=2000000' "$S")" "1"
ensure_kv "$S" "DefaultLimitNOFILE" "3000000"  # replace
check "kv replaced" "$(grep -c 'DefaultLimitNOFILE=3000000' "$S")" "1"
check "old kv value gone" "$(grep -c 'DefaultLimitNOFILE=2000000' "$S")" "0"

echo "== ensure_block =="
G="$WORK/before.rules"
printf '*filter\n:ufw-before-input - [0:0]\n# End required lines\n' >"$G"
ensure_block "$G" "dz-gre" "-A ufw-before-input -p 47 -j ACCEPT"
ensure_block "$G" "dz-gre" "-A ufw-before-input -p 47 -j ACCEPT"  # idempotent
check "block markers present once" "$(grep -c '>>> deeploy:dz-gre >>>' "$G")" "1"
check "block content present once" "$(grep -c 'p 47 -j ACCEPT' "$G")" "1"
check "original content preserved" "$(grep -c 'End required lines' "$G")" "1"
ensure_block "$G" "dz-gre" "-A ufw-before-input -p 47 -j ACCEPT
-A ufw-before-input -p 47 -j LOG"   # replace with multi-line
check "block replaced (markers still 1)" "$(grep -c '>>> deeploy:dz-gre >>>' "$G")" "1"
check "new line in block" "$(grep -c 'p 47 -j LOG' "$G")" "1"
remove_block "$G" "dz-gre"
check "block removed cleanly" "$(grep -c 'deeploy:dz-gre' "$G")" "0"
check "original survives removal" "$(grep -c 'End required lines' "$G")" "1"

echo "== backup_file =="
backup_file "$S"
check_true "backup exists" "[[ -f \"$DEEPLOY_BACKUP_DIR/$RUN_TS$S\" ]]"
check_true "manifest lists file" "grep -q \"$S\" \"$DEEPLOY_BACKUP_DIR/$RUN_TS/MANIFEST\""

echo "== state =="
state_set "phase-2" "done"
check_true  "state_has phase-2" "state_has phase-2"
check       "state_get phase-2" "$(state_get phase-2)" "done"
check_false "state_has phase-9" "state_has phase-9"
check       "state_get default" "$(state_get phase-9 MISSING)" "MISSING"
mark_phase_done 4
check_true "mark/is_phase_done" "is_phase_done 4"

echo "== non-interactive prompts use defaults =="
ask "PoH core" "2";                         check "ask default"        "$REPLY" "2"
ask_choice "MEV mode" "bam" bam relayer none; check "ask_choice default" "$REPLY" "bam"
confirm "proceed?" "Y";                      check "confirm default Y"  "$?" "0"
require_yes "wipe disk?" && rc=0 || rc=1;    check "require_yes refuses non-interactive" "$rc" "1"

echo "== dry-run changes nothing =="
D="$WORK/dry.conf"
DRY_RUN=1
ensure_line "$D" "should-not-write"
ensure_block "$D" "x" "nope"
state_set "phase-7" "should-not-persist"
# shellcheck disable=SC2034  # read back by sourced is_dry_run() in later tests
DRY_RUN=0
check_false "dry-run did not create file" "[[ -e \"$D\" ]]"
check_false "dry-run did not write state" "state_has phase-7"

echo "== ensure_block replaces by marker when content changes (A->B) =="
BK2="$WORK/grub.block"
ensure_block "$BK2" "poh" "isolcpus=domain,managed_irq,2,26"
ensure_block "$BK2" "poh" "isolcpus=domain,managed_irq,10,34"   # content changed
check "exactly one begin marker (no second block)" "$(grep -c '>>> deeploy:poh >>>' "$BK2")" "1"
check "new content present" "$(grep -c '2,26' "$BK2")" "0"
check "old content gone"    "$(grep -c '10,34' "$BK2")" "1"

echo "== backup captures ORIGINAL before overwrite =="
OF="$WORK/orig.conf"
printf 'ORIGINAL_CONTENT\n' >"$OF"
ensure_line "$OF" "ADDED_LINE"
OBK="$DEEPLOY_BACKUP_DIR/$RUN_TS$OF"
check_true "backup of original exists" "[[ -f \"$OBK\" ]]"
check "backup holds original"   "$(grep -c ORIGINAL_CONTENT "$OBK")" "1"
check "backup predates the edit" "$(grep -c ADDED_LINE "$OBK")" "0"
check "live file got the edit"   "$(grep -c ADDED_LINE "$OF")" "1"

echo "== write_file =="
WF="$WORK/gen/validator.sh"
write_file "$WF" "$(printf '#!/bin/bash\necho hi\n')"$'\n' 0700
check_true "write_file created"        "[[ -f \"$WF\" ]]"
check_true "write_file applied mode"   "[[ -x \"$WF\" ]]"
check "write_file content correct"     "$(grep -c 'echo hi' "$WF")" "1"
write_file "$WF" "$(printf '#!/bin/bash\necho bye\n')"$'\n' 0700  # overwrite
check "write_file overwrote"           "$(grep -c bye "$WF")" "1"
check_true "write_file backed up prior" "[[ -f \"$DEEPLOY_BACKUP_DIR/$RUN_TS$WF\" ]]"

echo "== apply_sysctl_file: tolerant under set -e (missing key warns, others apply) =="
# Mock sysctl: accept everything EXCEPT keys under a missing subtree (fs.xfs.*),
# which a fresh box rejects with non-zero — the exact crash we are guarding.
SYSCTL_LOG="$WORK/sysctl.log"; : >"$SYSCTL_LOG"
sysctl() {   # shadow real sysctl
    if [[ "$1" == "-w" ]]; then
        case "$2" in
            fs.xfs.*) return 1 ;;                       # subtree not present yet
            *) echo "$2" >>"$SYSCTL_LOG"; return 0 ;;
        esac
    fi
}
SF="$WORK/sysctl.d.conf"
printf '%s\n' '# a comment' '' 'vm.swappiness=0' 'net.core.rmem_max=134217728' 'fs.xfs.xfssyncd_centisecs=10000' 'net.ipv4.tcp_rmem=10240 87380 12582912' >"$SF"
# The whole point: this must NOT abort under the installer's production flags.
APPLY_OUT=$( set -Eeuo pipefail; apply_sysctl_file "$SF" 2>&1 ); APPLY_RC=$?
check "apply_sysctl_file returns 0 under set -Eeuo (no abort)" "$APPLY_RC" "0"
check "good keys applied (swappiness)"      "$(grep -c '^vm.swappiness=0$' "$SYSCTL_LOG")" "1"
check "good keys applied (rmem_max)"        "$(grep -c 'net.core.rmem_max=134217728' "$SYSCTL_LOG")" "1"
check "multi-value key kept whole (tcp_rmem)" "$(grep -c 'net.ipv4.tcp_rmem=10240 87380 12582912' "$SYSCTL_LOG")" "1"
check "missing-subtree key NOT applied"     "$(grep -c 'fs.xfs' "$SYSCTL_LOG")" "0"
check "missing key produces a WARN naming it" "$(grep -c "fs.xfs.xfssyncd_centisecs' not accepted" <<<"$APPLY_OUT")" "1"
unset -f sysctl

echo "== phase_begin / phase_end =="
phase_begin 3 "Disk"
check "current-phase recorded"  "$(state_get current-phase)" "3:Disk"
check "CURRENT_PHASE var set"    "$CURRENT_PHASE" "3"
phase_end 3
check_true  "phase 3 marked done"     "is_phase_done 3"
check_false "current-phase cleared"   "state_has current-phase"

echo "== exit trap leaves actionable footer =="
# shellcheck disable=SC2034  # consumed inside the eval'd check_true expressions
trapout=$( ( set -Eeuo pipefail; deeploy_init_traps; phase_begin 5 "Toolchain"; false ) 2>&1 )
check_true "footer: aborted"      "grep -q 'DeePloy aborted' <<<\"\$trapout\""
check_true "footer: names phase"  "grep -q 'phase 5 (Toolchain)' <<<\"\$trapout\""
check_true "footer: resume hint"  "grep -q 'Resume:' <<<\"\$trapout\""
check_true "footer: backups hint" "grep -q 'Backups:' <<<\"\$trapout\""

echo "== statedir-unavailable: root loud, non-root quiet =="
rootmsg=$(_common_statedir_unavailable 1 2>&1)
nonrootmsg=$(_common_statedir_unavailable 0 2>&1)
check "root fault is loud (DISABLED)"   "$(grep -c 'DISABLED' <<<"$rootmsg")"        "1"
check "root fault names root"           "$(grep -ci 'as root' <<<"$rootmsg")"        "1"
check "non-root is quiet (console)"     "$(grep -c 'console only' <<<"$nonrootmsg")" "1"
check "non-root NOT flagged DISABLED"   "$(grep -c 'DISABLED' <<<"$nonrootmsg")"     "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
