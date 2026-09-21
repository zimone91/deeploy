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
# constants.sh carries DEEPLOY_MIN_JITO_TAG, the default floor for the tag predicate
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"

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

echo "== 7c: require_yes IGNORES --yes/ASSUME_YES=1 (the README's central claim) =="
RY=$( ASSUME_YES=1 NONINTERACTIVE=0 require_yes "wipe?" <<<"no" >/dev/null && echo PROCEEDED || echo blocked )
check "7c: --yes + typed 'no' -> still blocked"      "$RY" "blocked"
RY2=$( ASSUME_YES=1 NONINTERACTIVE=0 require_yes "wipe?" <<<"" >/dev/null && echo PROCEEDED || echo blocked )
check "7c: --yes + bare Enter -> still blocked"      "$RY2" "blocked"
RY3=$( ASSUME_YES=1 NONINTERACTIVE=0 require_yes "wipe?" <<<"yes" >/dev/null && echo proceeded || echo BLOCKED )
check "7c: a TYPED 'yes' still proceeds"             "$RY3" "proceeded"
RY4=$( ASSUME_YES=1 NONINTERACTIVE=1 require_yes "wipe?" </dev/null >/dev/null && echo PROCEEDED || echo blocked )
check "7c: --yes + non-interactive -> refused"       "$RY4" "blocked"
# the intended asymmetry: ordinary confirm() DOES honor --yes
RY5=$( ASSUME_YES=1 NONINTERACTIVE=0 confirm "ordinary?" </dev/null >/dev/null && echo proceeded || echo BLOCKED )
check "7c: confirm still honors --yes (asymmetry intact)" "$RY5" "proceeded"

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

echo "== N8: deeploy_checkout_unsafe_reason — the ONE predicate both callers share =="
# Shared by preflight (phase 0) and the install-time gate; duplicating it is the
# N5/N13 drift class, so it is tested once, here, against every branch.
deeploy_path_uid()  { echo 0; }
deeploy_path_mode() { echo 755; }
CKW=$(deeploy_checkout_unsafe_reason /some/dir /some/dir/deeploy.sh); CKRC=$?
check "safe checkout -> rc0, says nothing"   "${CKRC}/${CKW}" "0/"
deeploy_path_uid() { echo 501; }
CKW=$(deeploy_checkout_unsafe_reason /some/dir); CKRC=$?
check "non-root -> rc1"                      "$CKRC" "1"
check "non-root -> names path + uid"         "$(grep -c "^/some/dir is not root-owned (uid 501)$" <<<"$CKW")" "1"
deeploy_path_uid() { echo 0; }
deeploy_path_mode() { echo 775; }
CKW=$(deeploy_checkout_unsafe_reason /some/dir); CKRC=$?
check "group-writable -> rc1"                "$CKRC" "1"
check "group-writable -> names mode"         "$(grep -c 'group/world-writable (mode 775)' <<<"$CKW")" "1"
deeploy_path_mode() { echo 757; }            # world-writable
( deeploy_checkout_unsafe_reason /some/dir ) >/dev/null 2>&1
check "world-writable -> rc1"                "$?" "1"
deeploy_path_mode() { echo ""; }             # stat unreadable -> fail CLOSED
CKW=$(deeploy_checkout_unsafe_reason /some/dir); CKRC=$?
check "unreadable mode -> rc1 (fail-closed)" "$CKRC" "1"
check "unreadable mode -> reported as ?"     "$(grep -c 'mode ?' <<<"$CKW")" "1"
# every path is checked, not just the first
deeploy_path_mode() { echo 755; }
deeploy_path_uid() { case "$1" in *bad*) echo 501;; *) echo 0;; esac; }
CKW=$(deeploy_checkout_unsafe_reason /good/dir /good/bad-file); CKRC=$?
check "second path is checked too"           "$CKRC" "1"
check "second path is the one named"         "$(grep -c '/good/bad-file' <<<"$CKW")" "1"

echo "== N8c: deeploy_not_executable_reason — can this file actually run =="
# Kept separate from the predicate above on purpose. That one answers who may
# WRITE the file; this one answers whether it can RUN. Folding them would make
# the other's ok line ("root-owned and not group/world-writable") claim a
# property it never measured.
NXF="$WORK/runnable.sh"; printf '#!/bin/bash\n' >"$NXF"
deeploy_path_mode() { echo 755; }
NXW=$(deeploy_not_executable_reason "$NXF"); NXRC=$?
check "executable -> rc0, says nothing"       "${NXRC}/${NXW}" "0/"
deeploy_path_mode() { echo 644; }
NXW=$(deeploy_not_executable_reason "$NXF"); NXRC=$?
check "mode 644 -> rc1"                       "$NXRC" "1"
check "  and the reason names the mode"       "$(grep -c 'is mode 644' <<<"$NXW")" "1"
# 0644 with a leading zero is the same file; the arithmetic must not read it as
# decimal or as an invalid octal literal.
deeploy_path_mode() { echo 0644; }
( deeploy_not_executable_reason "$NXF" ) >/dev/null 2>&1
check "mode 0644 (leading zero) -> rc1"       "$?" "1"
deeploy_path_mode() { echo 0755; }
( deeploy_not_executable_reason "$NXF" ) >/dev/null 2>&1
check "mode 0755 (leading zero) -> rc0"       "$?" "0"
# Owner-only execute still runs for root, which is who the boot unit is.
deeploy_path_mode() { echo 700; }
( deeploy_not_executable_reason "$NXF" ) >/dev/null 2>&1
check "mode 700 -> rc0 (root can run it)"     "$?" "0"
# Unanswerable, not absent: a mode that cannot be read is a refusal of its own,
# distinct from a file that is simply not executable.
deeploy_path_mode() { echo ""; }
NXW=$(deeploy_not_executable_reason "$NXF"); NXRC=$?
check "unreadable mode -> rc1"                "$NXRC" "1"
check "  and says the mode could not be read" "$(grep -c 'could not be read' <<<"$NXW")" "1"
deeploy_path_mode() { echo 755; }
NXW=$(deeploy_not_executable_reason "$WORK/no-such-file.sh"); NXRC=$?
check "missing file -> rc1"                   "$NXRC" "1"
check "  and says it does not exist"          "$(grep -c 'does not exist' <<<"$NXW")" "1"

echo "== N8: the surface is deeploy.sh AND every module it sources =="
# The unit written at the reboot boundary runs deeploy.sh as root, and deeploy.sh
# sources lib/*.sh before it does anything at all. A module a local user can
# write is therefore the same root-persistence vector as a writable deeploy.sh,
# one directory down — and the two-path predicate above cannot see it.
SURF="$WORK/surface"; mkdir -p "$SURF/lib"
: > "$SURF/deeploy.sh"; : > "$SURF/lib/common.sh"; : > "$SURF/lib/disk.sh"
deeploy_path_mode() { echo 755; }
deeploy_path_uid()  { echo 0; }
SW=$(deeploy_root_surface_unsafe_reason "$SURF" "$SURF/deeploy.sh" "$SURF/lib"); SRC=$?
check "all root-owned -> rc0, says nothing"  "${SRC}/${SW}" "0/"

# dir and deeploy.sh stay root-owned; ONE module does not.
deeploy_path_uid() { case "$1" in *disk.sh) echo 501 ;; *) echo 0 ;; esac; }
SW=$(deeploy_root_surface_unsafe_reason "$SURF" "$SURF/deeploy.sh" "$SURF/lib"); SRC=$?
check "a user-owned module -> rc1"           "$SRC" "1"
check "and the module is the path named"     "$(grep -c 'lib/disk.sh is not root-owned' <<<"$SW")" "1"
# This is the gap, stated as an assertion rather than as a claim in a commit
# message: the predicate this replaced passes the very same tree.
SW2=$(deeploy_checkout_unsafe_reason "$SURF" "$SURF/deeploy.sh"); SRC2=$?
check "the two-path predicate calls it safe" "${SRC2}/${SW2}" "0/"

deeploy_path_uid() { echo 0; }
deeploy_path_mode() { case "$1" in *common.sh) echo 775 ;; *) echo 755 ;; esac; }
SW=$(deeploy_root_surface_unsafe_reason "$SURF" "$SURF/deeploy.sh" "$SURF/lib"); SRC=$?
check "a group-writable module -> rc1"       "$SRC" "1"
check "and names it"                         "$(grep -c 'lib/common.sh is group/world-writable' <<<"$SW")" "1"

# An empty lib/ contributes nothing rather than expanding to a literal glob:
# the modules would fail to source anyway, and a bogus path here would report
# the wrong reason for the right refusal.
deeploy_path_mode() { echo 755; }
mkdir -p "$SURF/emptylib"
SW=$(deeploy_root_surface_unsafe_reason "$SURF" "$SURF/deeploy.sh" "$SURF/emptylib"); SRC=$?
check "no modules -> rc0, no phantom path"   "${SRC}/${SW}" "0/"
unset -f deeploy_path_uid deeploy_path_mode

echo "== tag parsing: vMAJOR.MINOR.PATCH out of jito-solana tag shapes =="
check "stable tag"          "$(deeploy_tag_version v4.2.1-jito)"          "4 2 1"
check "floor tag"           "$(deeploy_tag_version v4.2.0-jito)"          "4 2 0"
check "old tag"             "$(deeploy_tag_version v4.0.0-jito)"          "4 0 0"
check "prerelease shape"    "$(deeploy_tag_version v4.2.0-beta.2-jito.1)" "4 2 0"
check "rc shape"            "$(deeploy_tag_version v4.2.0-rc.1-jito)"     "4 2 0"
# garbage does NOT parse — it used to be substituted straight into the anza URL
for bad in latest v4.2 4.2.1-jito "" vX.Y.Z-jito; do
    ( deeploy_tag_version "$bad" ) >/dev/null 2>&1
    check "rejects '${bad:-<empty>}'" "$?" "1"
done

echo "== version floor: the ONE predicate behind all three checks =="
check_true "floor constant is itself a version tag" "deeploy_tag_version \"\$DEEPLOY_MIN_JITO_TAG\" >/dev/null"
for good in v4.2.0-jito v4.2.1-jito v4.3.0-jito v5.0.0-jito; do
    ( deeploy_tag_floor_problem "$good" ) >/dev/null 2>&1
    check "accepts $good" "$?" "0"
done
for old in v4.1.2-jito v4.1.0-jito v4.0.0-jito v3.1.14-jito; do
    ( deeploy_tag_floor_problem "$old" ) >/dev/null 2>&1
    check "refuses $old" "$?" "1"
done
FLOORWHY=$(deeploy_tag_floor_problem v4.0.0-jito); FLOORRC=$?
check "old tag -> rc1"                   "$FLOORRC" "1"
check "reason names tag AND the floor"   "$(grep -c "v4.0.0-jito is older than the minimum supported ${DEEPLOY_MIN_JITO_TAG}" <<<"$FLOORWHY")" "1"
GARBWHY=$(deeploy_tag_floor_problem latest); GARBRC=$?
check "garbage -> rc1"                   "$GARBRC" "1"
check "reason says it is not a tag"      "$(grep -c 'is not a jito-solana version tag' <<<"$GARBWHY")" "1"
# boundary: one patch below the floor is refused, the floor itself is not
( deeploy_tag_floor_problem v4.1.99-jito ) >/dev/null 2>&1; check "4.1.99 < 4.2.0" "$?" "1"
( deeploy_tag_floor_problem v4.2.0-jito )  >/dev/null 2>&1; check "4.2.0 == floor -> ok" "$?" "0"
# zero-padded components are decimal, not octal (would be a syntax error)
( deeploy_tag_floor_problem v4.08.0-jito ) >/dev/null 2>&1; check "v4.08.0 parses as 4.8.0 -> ok" "$?" "0"
# an unusable floor is reported as internal, never silently passed
UWHY=$(deeploy_tag_floor_problem v4.2.1-jito "not-a-tag"); URC=$?
check "bad floor -> rc1"                 "$URC" "1"
check "bad floor -> named internal"      "$(grep -c 'internal: version floor' <<<"$UWHY")" "1"

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
