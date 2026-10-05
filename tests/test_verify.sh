#!/usr/bin/env bash
# Self-contained tests for lib/verify.sh — the _vf_* probe wrappers are
# overridden to inject a "good" or "bad" system, asserting ok vs warn/fail.
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/verify.sh
source "$ROOT/lib/verify.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
reset() { _VF_WARN=0; _VF_FAIL=0; }

DRY_RUN=0 common_init
state_set isolated_set "1-2,10,25-26,34"
state_set poh_core 10

# "Good" system
_vf_pid()          { echo 12345; }
_vf_proc_limits()  { printf 'Max core file size        0           0           bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
_vf_coredump_filter() { echo 00000010; }
_vf_proc_nice()    { echo "-10"; }
_vf_oom_score()    { echo "-1000"; }
_vf_poh_thread()   { echo 999; }
_vf_taskset()      { echo "10"; }
_vf_isolated()     { echo "1-2,10,25-26,34"; }
_vf_governor()     { echo performance; }
_vf_thp()          { echo "always madvise [never]"; }
_vf_ksm()          { echo 0; }
_vf_numa()         { echo 0; }
_vf_sysctl()       { case "$1" in net.core.rmem_max) echo 134217728;; fs.nr_open) echo 2000000;; esac; }
_vf_catchup()      { echo "0 slot(s) behind (us:100 them:100)"; }
_vf_timer_active() { echo active; }

echo "== good system: every check clean =="
reset; verify_process      >/dev/null 2>&1; check "process running"  "$_VF_FAIL/$_VF_WARN" "0/0"
reset; verify_limits       >/dev/null 2>&1; check "limits ok"        "$_VF_WARN" "0"
reset; verify_priority     >/dev/null 2>&1; check "priority ok"      "$_VF_WARN" "0"
reset; verify_isolation    >/dev/null 2>&1; check "isolation ok"     "$_VF_FAIL" "0"
reset; verify_poh_affinity >/dev/null 2>&1; check "poh affinity ok"  "$_VF_WARN" "0"
reset; verify_perf_tweaks  >/dev/null 2>&1; check "perf tweaks ok"   "$_VF_WARN" "0"
reset; verify_sysctl       >/dev/null 2>&1; check "sysctl ok"        "$_VF_WARN" "0"
reset; verify_catchup      >/dev/null 2>&1; check "catchup ok"       "$_VF_WARN" "0"
reset; verify_pohpin_timer >/dev/null 2>&1; check "timer ok"         "$_VF_WARN" "0"

echo "== env-class: verify_run resolves SOLANA_BIN absolute with HOME UNSET (systemd) =="
# verify runs inside Phase 8 via the resume service, where $HOME is empty. The
# source-time default would be '/.local/...'; verify_run must re-resolve HOME-free.
( unset SOLANA_BIN
  state_set solana_bin "/root/.local/share/solana/install/active_release/bin"
  HOME="" verify_run >/dev/null 2>&1
  echo "$SOLANA_BIN" ) >"$WORK/vbin" 2>&1
check "verify SOLANA_BIN from state (HOME unset)" "$(cat "$WORK/vbin")" "/root/.local/share/solana/install/active_release/bin"
check "verify never '/.local' (empty-HOME) path"  "$(grep -c '^/\.local' "$WORK/vbin")" "0"

echo "== bad system: failures + warnings detected =="
_vf_pid() { echo ""; }
reset; verify_process >/dev/null 2>&1; check "no process -> FAIL" "$_VF_FAIL" "1"
_vf_pid() { echo 12345; }
_vf_isolated() { echo "10,34"; }
reset; verify_isolation >/dev/null 2>&1; check "isolation mismatch -> FAIL" "$_VF_FAIL" "1"
_vf_isolated() { echo "1-2,10,25-26,34"; }
VF_PID=12345   # restore (the no-process test left it empty)
_vf_taskset() { echo "5"; }
reset; verify_poh_affinity >/dev/null 2>&1; check "poh wrong core -> warn" "$_VF_WARN" "1"
_vf_taskset() { echo "10"; }
_vf_governor() { echo powersave; }
reset; verify_perf_tweaks >/dev/null 2>&1; check "bad governor -> >=1 warn" "$([[ $_VF_WARN -ge 1 ]] && echo y || echo n)" "y"
_vf_governor() { echo performance; }
_vf_catchup() { echo "85 slot(s) behind (us:10 them:95)"; }
reset; verify_catchup >/dev/null 2>&1; check "behind -> warn" "$_VF_WARN" "1"
_vf_catchup() { echo "0 slot(s) behind"; }

echo "== R10-6: identity — on the sync key is a WARN that names both cases =="
STK=kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu; SYN=SyncPk1111111111111111111111111111111111111
LIVE=""; _vf_identity() { printf '%s' "$LIVE"; }; _vf_sync_pubkey() { printf '%s' "$SYN"; }
state_clear staked_pubkey
LIVE=$SYN; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: no staked pubkey recorded -> skipped, no warn" "$_VF_WARN|$(grep -c 'identity check skipped' "$WORK/id")" "0|1"
state_set staked_pubkey "$STK"
LIVE=$STK; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: live == staked -> ok"             "$_VF_WARN|$(grep -c "running on the staked identity $STK" "$WORK/id")" "0|1"
LIVE=$SYN; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: live == sync -> WARN"             "$_VF_WARN|$(grep -c 'NOT voting as staked' "$WORK/id")" "1|1"
check "R10-6: the WARN names both cases"        "$(grep -c 'expected before the swap; after a swap it means a restart reverted the identity' "$WORK/id")" "1"
LIVE=AnotherPk11111111111111111111111111111111111; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: neither staked nor sync -> WARN"  "$_VF_WARN|$(grep -c 'is neither the staked' "$WORK/id")" "1|1"
LIVE=""; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: no answer from getIdentity -> WARN" "$_VF_WARN|$(grep -c 'did not answer' "$WORK/id")" "1|1"
state_clear staked_pubkey

echo "== R10-10: no core dumps (the validator's memory holds its identity key) =="
reset; verify_limits >"$WORK/lim" 2>&1
check "R10-10: core 0/0 -> ok"                 "$(grep -cF 'core dump limit (soft/hard) = 0/0' "$WORK/lim")" "1"
check "R10-10: coredump_filter 00000010 -> ok" "$(grep -cF 'coredump_filter = 00000010' "$WORK/lim")" "1"
# 00000033 is the kernel default, measured on the rc9 box.
_vf_coredump_filter() { echo 00000033; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: coredump_filter 00000033 -> warn" "$_VF_WARN" "1"
_vf_coredump_filter() { echo 00000010; }
_vf_proc_limits() { printf 'Max core file size        unlimited   unlimited   bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: core unlimited -> warn" "$_VF_WARN" "1"
# Soft 0 / hard unlimited was measured on the rc9 box: the process may raise it.
_vf_proc_limits() { printf 'Max core file size        0           unlimited   bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: core soft 0 / hard unlimited -> warn" "$_VF_WARN" "1"
_vf_proc_limits() { printf 'Max core file size        0           0           bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
# The real probes, on a pid that cannot exist, under DeePloy's ERR trap: a probe
# that fails inside $( ) would print a stray "[FAIL] line N" (ERR-NOISE-SUBST).
NOISE=$( ( unset _DEEPLOY_VERIFY_SOURCED
           # shellcheck source-path=SCRIPTDIR source=../lib/verify.sh
           source "$ROOT/lib/verify.sh"
           set -E; deeploy_init_traps; trap - EXIT; VF_PID=999999999; verify_limits ) 2>&1 )
check "R10-10: real probes, no such pid -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"

echo "== verify_run summary =="
verify_run >/dev/null 2>&1; check "all-good verify_run passes" "$?" "0"
_vf_isolated() { echo "wrong-set"; }
verify_run >/dev/null 2>&1; check "verify_run with a FAIL returns 1" "$?" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
