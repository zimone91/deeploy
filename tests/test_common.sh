#!/usr/bin/env bash
# Self-contained tests for lib/common.sh — no root, no network, no live node.
# Runs every public helper against temp dirs and asserts behavior.
#
# SC2016: printf'd helper scripts intentionally contain literal $PATH etc.
# SC2030/SC2031: env tweaks inside (..)/$(..) are deliberately subshell-local.
# shellcheck disable=SC2016,SC2030,SC2031
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

echo "== N15: state_set is atomic (temp-in-state-dir + rename, never truncate) =="
state_set atomkey "v1"
check "atomic: value round-trips"           "$(state_get atomkey)" "v1"
state_set atomkey "v2"
check "atomic: overwrite round-trips"       "$(state_get atomkey)" "v2"
# perms match the old plain-redirect creation (default umask -> 644)
# shellcheck disable=SC2012
check "atomic: file mode 644 (as before)"   "$(ls -l "$DEEPLOY_STATE_DIR/state.d/atomkey" | cut -c1-10)" "-rw-r--r--"
# a simulated mid-write kill: the RENAME fails -> the OLD value must survive
# intact (proves tmp-then-rename; an in-place '>file' would have truncated it)
mv() { return 1; }
state_set atomkey "v3" >/dev/null 2>&1 || true
unset -f mv
check "atomic: failed rename leaves the OLD value" "$(state_get atomkey)" "v2"
check "atomic: no temp litter left behind"  "$(find "$DEEPLOY_STATE_DIR/state.d" -name '.atomkey.*' | wc -l | tr -d ' ')" "0"

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

echo "== S3: write_file umask-protects RESTRICTIVE modes (perms from birth) =="
# _mode_is_restrictive truth table: true ONLY when no group/other READ bit.
check_true "0600 restrictive"  "_mode_is_restrictive 0600"
check_true "0700 restrictive"  "_mode_is_restrictive 0700"
check_true "0400 restrictive"  "_mode_is_restrictive 0400"
check_true "0644 NOT restrictive" "! _mode_is_restrictive 0644"
check_true "0755 NOT restrictive" "! _mode_is_restrictive 0755"
check_true "0640 NOT restrictive (group reads)" "! _mode_is_restrictive 0640"
check_true "garbage mode NOT restrictive"       "! _mode_is_restrictive nope"
# fresh write of a 0600 file -> born -rw------- (umask 077 path)
SF="$WORK/gen/secret.conf"
write_file "$SF" "$(printf 'TOPSECRET=1\n')" 0600
# shellcheck disable=SC2012  # symbolic perms via ls is portable (macOS + Linux)
check "fresh 0600 file is -rw-------"        "$(ls -l "$SF" | cut -c1-10)" "-rw-------"
check "fresh 0600 content correct"           "$(grep -c TOPSECRET "$SF")" "1"
# overwrite a PRE-EXISTING world-readable 0644 file with a 0600 write -> tightened
LF="$WORK/gen/loose.conf"; printf 'OLD=1\n' >"$LF"; chmod 0644 "$LF"
# shellcheck disable=SC2012
check "precondition: loose file is 0644"     "$(ls -l "$LF" | cut -c1-10)" "-rw-r--r--"
write_file "$LF" "$(printf 'NEW=1\n')" 0600
# shellcheck disable=SC2012
check "overwrite tightens to -rw-------"      "$(ls -l "$LF" | cut -c1-10)" "-rw-------"
check "overwrite updated content"            "$(grep -c NEW "$LF")" "1"
# narrow blast radius: 0644/0755 writes keep the normal (world-readable) path
NF="$WORK/gen/public.txt"; write_file "$NF" "$(printf 'pub\n')" 0644
# shellcheck disable=SC2012
check "0644 write stays -rw-r--r-- (unchanged path)"  "$(ls -l "$NF" | cut -c1-10)" "-rw-r--r--"
XF="$WORK/gen/pubscript.sh"; write_file "$XF" "$(printf '#!/bin/bash\n:\n')" 0755
# shellcheck disable=SC2012
check "0755 script stays -rwxr-xr-x (unchanged path)" "$(ls -l "$XF" | cut -c1-10)" "-rwxr-xr-x"

echo "== X4: run_redacted masks a flag value in logs but executes the real argv =="
check "redact: masks the token after the flag" "$(_redact_argv --signature cmd a --signature SECRET -k /p)" "cmd a --signature *** -k /p"
check "redact: flag absent -> unchanged"        "$(_redact_argv --signature cmd a b)" "cmd a b"
check "redact: trailing flag, no value -> as-is" "$(_redact_argv --signature cmd --signature)" "cmd --signature"
REC="$WORK/rec"; : >"$REC"
xrec() { printf '%s\n' "$*" >"$REC"; }   # records the argv it was actually called with
run_redacted --signature xrec --signature SECRET33 -k /path >/dev/null 2>&1
check "run_redacted EXECUTES the real argv (secret present)" "$(cat "$REC")" "--signature SECRET33 -k /path"
check "run_redacted LOGS the masked form"        "$(grep -c -- '+ xrec --signature \*\*\* -k /path' "$LOG_FILE")" "1"
check "run_redacted does NOT leak the secret to the log" "$(grep -c 'SECRET33' "$LOG_FILE")" "0"

echo "== deeploy_solana_bin: \$HOME-independent (systemd resume has empty HOME) =="
# Precedence: explicit SOLANA_BIN > state solana_bin > /root default. NEVER the
# empty-HOME '/.local/...' that broke Phase 8's catchup wait on the real box.
( export SOLANA_BIN="/explicit/bin"; deeploy_solana_bin ) >"$WORK/sb1" 2>&1
check "explicit SOLANA_BIN wins" "$(cat "$WORK/sb1")" "/explicit/bin"
( unset SOLANA_BIN; state_set solana_bin "/root/.local/share/solana/install/active_release/bin"
  HOME="" ; deeploy_solana_bin ) >"$WORK/sb2" 2>&1
check "state solana_bin used when no explicit (HOME unset)" "$(cat "$WORK/sb2")" "/root/.local/share/solana/install/active_release/bin"
state_clear solana_bin
( unset SOLANA_BIN; HOME="" ; deeploy_solana_bin ) >"$WORK/sb3" 2>&1
check "fallback base is /root (NOT empty-HOME /.local)" "$(cat "$WORK/sb3")" "/root/.local/share/solana/install/active_release/bin"
check "deeploy_solana_bin never yields a leading /.local" "$(grep -c '^/\.local' "$WORK/sb3")" "0"

echo "== R9: no module-scope SOLANA_BIN pre-seed (empty HOME can't poison it) =="
# Before R9 each module ran SOLANA_BIN="\${SOLANA_BIN:-\$HOME/.local/...}" at SOURCE
# time; under an empty HOME (cron/systemd) that became "/.local/..." and then
# SHADOWED deeploy_solana_bin's state-recorded resolution (its first branch returns
# an already-set SOLANA_BIN). Sourcing a module must now leave SOLANA_BIN UNSET so
# the resolve falls through to state -> the /root default.
for _m in doublezero keys start upgrade verify; do
    _sb="$(HOME="" bash -c '
        unset SOLANA_BIN
        source "'"$ROOT"'/lib/common.sh"
        source "'"$ROOT"'/lib/constants.sh"
        source "'"$ROOT"'/lib/'"$_m"'.sh"
        printf "%s" "${SOLANA_BIN:-<unset>}"' 2>&1)"
    check "lib/${_m}.sh does NOT pre-seed SOLANA_BIN (empty HOME)" "$_sb" "<unset>"
done

echo "== ensure_cargo_env: puts rustup cargo on PATH for the whole run =="
# Simulate a rustup install: ~/.cargo/bin/cargo + ~/.cargo/env, with bin NOT yet
# on PATH (the real-box bug: nic.sh couldn't find cargo after Phase 4).
CARGO_SBX="$WORK/cargohome"
mkdir -p "$CARGO_SBX/bin"
printf '#!/bin/bash\necho cargo "$@"\n' >"$CARGO_SBX/bin/cargo"; chmod +x "$CARGO_SBX/bin/cargo"
printf 'export PATH="%s/bin:$PATH"\n' "$CARGO_SBX" >"$CARGO_SBX/env"
( export CARGO_HOME="$CARGO_SBX" PATH="/usr/bin:/bin"   # cargo NOT reachable initially
  command -v cargo >/dev/null 2>&1 && echo PRE_FOUND || echo PRE_MISSING
  ensure_cargo_env
  command -v cargo >/dev/null 2>&1 && echo POST_FOUND || echo POST_MISSING ) >"$WORK/cargoenv.out" 2>&1
check "cargo NOT on PATH before"       "$(grep -c PRE_MISSING "$WORK/cargoenv.out")" "1"
check "ensure_cargo_env puts it on PATH" "$(grep -c POST_FOUND "$WORK/cargoenv.out")" "1"
# Idempotent: a second call must not double-prepend ~/.cargo/bin.
( export CARGO_HOME="$CARGO_SBX" PATH="/usr/bin:/bin"
  ensure_cargo_env; ensure_cargo_env
  awk -v p="$CARGO_SBX/bin" 'BEGIN{n=split(ENVIRON["PATH"],a,":"); c=0; for(i=1;i<=n;i++) if(a[i]==p) c++; print c}' ) >"$WORK/cargoenv2.out" 2>&1
check "idempotent: ~/.cargo/bin appears once" "$(cat "$WORK/cargoenv2.out")" "1"
# Safe no-op when cargo isn't installed at all (no env, no bin).
( export CARGO_HOME="$WORK/nocargo" PATH="/usr/bin:/bin"
  ensure_cargo_env; echo "rc=$?" ) >"$WORK/cargoenv3.out" 2>&1
check "no-op + returns 0 when cargo absent" "$(grep -c 'rc=0' "$WORK/cargoenv3.out")" "1"

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
