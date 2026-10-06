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
# DRY_RUN=1 without common_init: no shadow store, so state writes stay no-ops.
D="$WORK/dry.conf"
DRY_RUN=1
ensure_line "$D" "should-not-write"
ensure_block "$D" "x" "nope"
state_set "phase-7" "should-not-persist"
# shellcheck disable=SC2034  # read back by sourced is_dry_run() in later tests
DRY_RUN=0
check_false "dry-run did not create file" "[[ -e \"$D\" ]]"
check_false "dry-run did not write state" "state_has phase-7"
check "no common_init under dry-run -> no shadow" "${_STATE_SHADOW:-<none>}" "<none>"

echo "== R10-7e: dry-run state lives in a temp shadow, removed on exit =="
# Real values the dry-run must read through, hide on clear, and leave alone.
state_set shkeep real-k; state_set shgone real-g; mark_phase_done 6
state_sig() { ( cd "$DEEPLOY_STATE_DIR" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -f "$p" ]]; then printf '%s %s\n' "$p" "$(cat "$p")"; else printf '%s\n' "$p"; fi; done ); }
SIG0=$(state_sig)
mkdir -p "$WORK/sh1"
yn() { "$@" && echo y || echo n; }
SH=$( ( TMPDIR="$WORK/sh1"; DRY_RUN=1; common_init
        state_set shnew dry-v
        echo "new=$(state_get shnew none)"; echo "has=$(yn state_has shnew)"
        echo "keep=$(state_get shkeep none)"
        state_clear shgone; echo "gone=$(state_get shgone none)"; echo "gonehas=$(yn state_has shgone)"
        state_set shgone dry-back; echo "back=$(state_get shgone none)"; echo "backhas=$(yn state_has shgone)"
        state_set shtmp v; state_clear shtmp; echo "tmp=$(state_get shtmp none)"; echo "tmphas=$(yn state_has shtmp)"
        mark_phase_done 7; echo "p7=$(yn is_phase_done 7)"
        echo "p6=$(yn is_phase_done 6)"; clear_phase 6; echo "p6after=$(yn is_phase_done 6)"
        echo "dir=$_STATE_SHADOW" ) 2>/dev/null )
shv() { sed -n "s/^$1=//p" <<<"$SH"; }
check "shadow: a dry-run write reads back"           "$(shv new)|$(shv has)" "dry-v|y"
check "shadow: an untouched real value reads through" "$(shv keep)" "real-k"
check "shadow: state_clear hides the real value"     "$(shv gone)|$(shv gonehas)" "none|n"
check "shadow: state_set after a clear reads back"   "$(shv back)|$(shv backhas)" "dry-back|y"
check "shadow: set then cleared in the dry-run -> gone" "$(shv tmp)|$(shv tmphas)" "none|n"
check "shadow: is_phase_done from the shadow"        "$(shv p7)" "y"
check "shadow: clear_phase hides a real done phase"  "$(shv p6)|$(shv p6after)" "y|n"
SHDIR="$(shv dir)"
check_true "shadow: made under \$TMPDIR"              "[[ \"$SHDIR\" == \"$WORK/sh1/deeploy-dryrun.\"* && -d \"$SHDIR/set\" ]]"
check "shadow: the real store is unchanged"         "$(state_sig)" "$SIG0"
check_false "shadow: no dry-run key in the real store" "state_has shnew"
# The exit trap removes it: clean exit, refusal (fail), and TERM. Each TMPDIR
# holds a canary: the trap must remove the shadow, never TMPDIR itself.
for d in sh2 sh3 sh4; do mkdir -p "$WORK/$d"; : >"$WORK/$d/canary"; done
tmpleft() { if [[ -d "$1" ]]; then ( cd "$1" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' ); else printf '<no TMPDIR>'; fi; }
EX=$( ( set -Eeuo pipefail; TMPDIR="$WORK/sh2"; DRY_RUN=1; common_init; deeploy_init_traps
        state_set k v; [[ -f "$_STATE_SHADOW/set/k" ]] && echo made ) 2>/dev/null ); RC=$?
check "exit 0: the shadow was there during the run" "$EX|$RC" "made|0"
check "exit 0: shadow removed, TMPDIR + canary kept" "$(tmpleft "$WORK/sh2")" "canary "
EX=$( ( set -Eeuo pipefail; TMPDIR="$WORK/sh3"; DRY_RUN=1; common_init; deeploy_init_traps
        state_set k v; [[ -f "$_STATE_SHADOW/set/k" ]] && echo made; fail "boom" ) 2>/dev/null ); RC=$?
check "refusal: the shadow was there, rc 1"          "$EX|$RC" "made|1"
check "refusal: shadow removed, TMPDIR + canary kept" "$(tmpleft "$WORK/sh3")" "canary "
# TERM in a separate bash: $$ there is that process, never this suite.
EX=$(bash -c 'set -Eeuo pipefail; source "$1"; TMPDIR=$2; DRY_RUN=1; common_init; deeploy_init_traps
        state_set k v; [[ -f "$_STATE_SHADOW/set/k" ]] && echo made; kill -TERM $$; echo after' _ "$ROOT/lib/common.sh" "$WORK/sh4" 2>/dev/null); RC=$?
check "TERM: the shadow was there, the run stopped"  "$EX|$RC" "made|1"
check "TERM: shadow removed, TMPDIR + canary kept"   "$(tmpleft "$WORK/sh4")" "canary "
# No temp dir -> refuse, with what to do; never plan from defaults.
MK=$( ( TMPDIR="$WORK/no-such-dir"; DRY_RUN=1; common_init; echo "went on" ) 2>&1 ); RC=$?
check "no temp dir: refused (rc 1)"                  "$RC" "1"
check "no temp dir: says to set TMPDIR"              "$(grep -c 'Set TMPDIR to a writable directory and run again' <<<"$MK")" "1"
check "no temp dir: did not go on"                   "$(grep -c 'went on' <<<"$MK")" "0"
# The environment cannot name a dir for the exit trap to remove: sourcing
# common.sh resets _STATE_SHADOW. A fresh bash gets a victim dir with a canary
# in its environment, before the source.
for d in victim1 victim2; do mkdir -p "$WORK/$d"; : >"$WORK/$d/canary"; done
_STATE_SHADOW="$WORK/victim1" bash -c 'set -Eeuo pipefail; source "$1"; DRY_RUN=0; common_init; deeploy_init_traps; exit 0' \
    _ "$ROOT/lib/common.sh" >/dev/null 2>&1; RC=$?
check "env-named shadow, a real run exits 0: the dir stays" "$RC|$(tmpleft "$WORK/victim1")" "0|canary "
# Traps first here, so the refusal runs the exit trap.
_STATE_SHADOW="$WORK/victim2" bash -c 'set -Eeuo pipefail; source "$1"; deeploy_init_traps; TMPDIR=$2; DRY_RUN=1; common_init; echo went-on' \
    _ "$ROOT/lib/common.sh" "$WORK/no-such-dir" >/dev/null 2>&1; RC=$?
check "env-named shadow, a dry-run refused: the dir stays" "$RC|$(tmpleft "$WORK/victim2")" "1|canary "
state_clear shkeep; state_clear shgone; clear_phase 6

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

echo "== jito tag shape: the Agave base a jito tag names, or nothing =="
# The base is the Anza release name phase 4 installs the CLI from. ${TAG%-jito}
# left v4.3.0-jito.0 whole (a 404 at release.anza.xyz), and a bare Agave tag
# passed with a warning.
while read -r tag want; do
    TBASE=$(deeploy_tag_agave_base "$tag"); TBRC=$?
    check "accepts $tag -> $want" "${TBRC}/${TBASE}" "0/${want}"
done <<'EOT'
v4.3.0-jito.0 v4.3.0
v4.3.0-jito v4.3.0
v4.2.1-jito v4.2.1
v4.2.0-beta.2-jito.1 v4.2.0-beta.2
v4.3.0-rc.1-jito.1 v4.3.0-rc.1
v4.4.0-alpha.3-jito.1 v4.4.0-alpha.3
v4.3.0-jito.12 v4.3.0
EOT
# A free-form prerelease would let v4.3.0-jito-jito and v4.3.0-bam-jito through,
# and their bases have no Anza release either; a prerelease needs its number
# (v4.3.0-rc-jito). The last four test both anchors: a leading space, a leading
# letter, a trailing space and a trailing newline.
SHAPE_BAD=(v4.3.0 v4.3.0-jito.x v4.3.0-jito. v4.3-jito latest "" v4.3.0-jito-jito
           v4.3.0-bam-jito v4.3.0-rc-jito v4.3.0-JITO v4.3.0-jito.0+meta
           v4.3.0-jito-1 v4.3.0-jito.0.1 4.3.0-jito
           ' v4.3.0-jito.0' 'xv4.3.0-jito.0' 'v4.3.0-jito.0 ' $'v4.3.0-jito\n')
for bad in "${SHAPE_BAD[@]}"; do
    TBASE=$(deeploy_tag_agave_base "$bad"); TBRC=$?
    check "refuses $(printf '%q' "$bad"), prints nothing" "${TBRC}/${TBASE}" "1/"
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
check "reason spells out the form"       "$(grep -cF 'vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N]' <<<"$GARBWHY")" "1"
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
echo "== R10-6: b58_len — decoded byte length (pubkey 32, signature 64) =="
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
check "32 x '1' -> 32 zero bytes (leading '1's)"   "$(b58_len "$(rep 1 32)")" "32"
check "Vote111…(43) -> 32 bytes"                    "$(b58_len Vote111111111111111111111111111111111111111)" "32"
check "the SPL Token program id -> 32 bytes"      "$(b58_len TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA)" "32"
check "'2' + 42 x '1' -> 31 bytes"                  "$(b58_len "2$(rep 1 42)")" "31"
check "44 x 'z' -> 33 bytes"                        "$(b58_len "$(rep z 44)")" "33"
check "87 x 'z' -> 64 bytes (signature size)"       "$(b58_len "$(rep z 87)")" "64"
check "88 x 'z' -> 65 bytes"                        "$(b58_len "$(rep z 88)")" "65"
for c in 0 O I l; do
    check "'$c' is outside the alphabet -> nothing" "$(b58_len "Vote1111${c}11111111111111111111111111111111")" ""
done
check "empty -> nothing"                            "$(b58_len "")" ""
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; b58_len "0bad"; b58_len "" ) 2>&1 )
check "invalid input under the ERR trap -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"

echo "== R10-4: catchup status — two bounded getSlot reads =="
# getSlot mock: the node (127.0.0.1) answers $US, the cluster $THEM. DOWN = no
# answer (curl's exit and message for a refused connection), ERR = a JSON-RPC
# error, GARBAGE = an HTML page, SP<n> = <n> with spaces in the JSON. Each
# call's arguments go to $SLOTS, one line per call.
SLOTS="$WORK/slots"
curl() {
    local url=${!#} a
    printf '%s\n' "$*" >>"$SLOTS"
    case "$url" in http://127.0.0.1:*) a=$US ;; *) a=$THEM ;; esac
    case "$a" in
        DOWN)    echo "curl: (7) Failed to connect to ${url#*//} after 0 ms: Couldn't connect to server" >&2; return 7 ;;
        ERR)     echo '{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":1}' ;;
        GARBAGE) echo '<html>502 Bad Gateway</html>' ;;
        SP*)     printf '{"jsonrpc": "2.0", "result" : %s, "id": 1}\n' "${a#SP}" ;;
        *)       printf '{"jsonrpc":"2.0","result":%s,"id":1}\n' "$a" ;;
    esac
}
status() { US=$1 THEM=$2; : >"$SLOTS"; deeploy_catchup_status 2>&1; }
NODE="no slot from the node's RPC at http://127.0.0.1:8899"
check "behind -> 'N slots behind (us:N them:M)'"      "$(status 10 95)"       "85 slots behind (us:10 them:95)"
check "level -> caught up"                            "$(status 100 100)"     "caught up (us:100 them:100)"
check "ahead -> caught up"                            "$(status 101 100)"     "caught up (us:101 them:100)"
check "4 behind -> caught up (the CLI's window)"      "$(status 96 100)"      "caught up (us:96 them:100)"
check "5 behind -> '5 slots behind'"                  "$(status 95 100)"      "5 slots behind (us:95 them:100)"
check "spaces in the JSON are read"                   "$(status SP10 SP95)"   "85 slots behind (us:10 them:95)"
check "the node silent -> says so, no curl message"   "$(status DOWN 95)"     "$NODE"
check "the node's JSON-RPC error -> no slot"          "$(status ERR 95)"      "$NODE"
check "the node's HTML page -> no slot"               "$(status GARBAGE 95)"  "$NODE"
check "the cluster silent -> says so, the node's slot" "$(status 10 DOWN)"    "no slot from the cluster RPC at https://api.mainnet-beta.solana.com (us:10)"
check "both silent -> the node's RPC is named"        "$(status DOWN DOWN)"   "$NODE"
status 10 95 >/dev/null
check "the cluster's slot is read first"              "$(sed 's/.* //' "$SLOTS" | tr '\n' ' ')" "https://api.mainnet-beta.solana.com http://127.0.0.1:8899 "
check "each read is capped at 5 s"                    "$(grep -c -- ' -m 5 ' "$SLOTS")" "2"
check "each read is getSlot at confirmed"             "$(grep -cF '"method":"getSlot","params":[{"commitment":"confirmed"}]' "$SLOTS")" "2"
check "each read sends Content-Type: application/json" "$(grep -cF 'Content-Type: application/json' "$SLOTS")" "2"
state_set rpc_port 8901
check "the node's port from state (rpc_port)"         "$(status DOWN 95)"     "no slot from the node's RPC at http://127.0.0.1:8901"
state_clear rpc_port
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; US=10 THEM=DOWN; deeploy_catchup_status; US=DOWN THEM=95; deeploy_catchup_status ) 2>&1 )
check "failed reads under the ERR trap -> the status lines only" "$NOISE" "no slot from the cluster RPC at https://api.mainnet-beta.solana.com (us:10)
$NODE"
unset -f curl

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
