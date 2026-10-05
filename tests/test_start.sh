#!/usr/bin/env bash
# Self-contained tests for lib/start.sh — systemctl/solana/df mocked.
# Covers the disk precheck, enable+start, catchup-wait, and the final summary
# (set-identity PATH form, no stdin form, failover pointer).
#
# Mocks shadow real commands and are invoked indirectly.
# The solana stubs are printf'd as scripts with a literal $$ / $* on purpose.
# shellcheck disable=SC2329,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
mkdir -p "$WORK/bin"
# The catchup wait must never run 'solana' (R10-4); this stub records a call.
printf '#!/bin/bash\necho "solana $*" >>"%s"\n' "$WORK/solana.calls" >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"
export SOLANA_BIN="$WORK/bin"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"       # DEFAULT_PUBLIC_RPC: the cluster's slot in the catchup wait
# shellcheck source-path=SCRIPTDIR source=../lib/start.sh
source "$ROOT/lib/start.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/keys.sh
source "$ROOT/lib/keys.sh"            # keys_print_swap_steps: the summary prints the swap

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_ge()    { if (( $2 >= $3 )); then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s (%s<%s)\n' "$1" "$2" "$3"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
require_root() { :; }
systemctl()    { echo "systemctl $*" >>"$CALLS"; return 0; }
ln()           { echo "ln $*" >>"$CALLS"; }

state_set solana_home /root/solana
state_set ledger_path /root/solana/ledger
state_set accounts_path /mnt/accounts/solana/accounts
state_set snapshots_path /root/solana/snapshots
state_set staked_keypair /root/solana/mainnet-validator-keypair.json
state_set vote_account_pubkey Vote1111111111111111111111111111111111111111
state_set dz_enabled true     # the dz-finalize summary pointer keys on ENABLEMENT (was dz_multicast: latent bug, fixed)
start_resolve_config

echo "== disk precheck =="
_start_free_gb() { echo 1800; }   # plenty
WARNS=$(start_precheck_disk 2>&1); check "ample free -> no WARN" "$(grep -c '\[WARN\]' <<<"$WARNS")" "0"
_start_free_gb() { echo 50; }     # low
WARNS=$(start_precheck_disk 2>&1); check_ge "low free -> warns" "$(grep -c '\[WARN\]' <<<"$WARNS")" "1"

echo "== N15: free-space check on a MISSING dir warns + reports 0 (fail-closed) =="
# Use the REAL _start_free_gb (re-source; the lines above mocked it): a missing
# dir used to silently skip the check — the exact data-mount-didn't-come-up case.
_DEEPLOY_START_SOURCED="" source "$ROOT/lib/start.sh"
MISSOUT=$(_start_free_gb "$WORK/definitely-missing-dir" 2>&1)
check "missing dir -> reports 0G"          "$(tail -1 <<<"$MISSOUT")" "0"
check "missing dir -> warns (mount up?)"   "$(grep -c 'does not exist' <<<"$MISSOUT")" "1"
# and the precheck turns that 0 into its low-space warns (both filesystems)
state_set accounts_path "$WORK/missing/acc"; state_set snapshots_path "$WORK/missing/snap"
start_resolve_config
PRE=$(start_precheck_disk 2>&1)
check_ge "precheck warns on missing mounts" "$(grep -c '\[WARN\]' <<<"$PRE")" "2"
state_set accounts_path /mnt/accounts/solana/accounts
state_set snapshots_path /root/solana/snapshots
start_resolve_config
_start_free_gb() { echo 1800; }

echo "== enable + start: IDEMPOTENT (adopt a running node; never restart mid-snapshot) =="
# Not running -> enable + START (not restart). _start_solana_running false.
_start_solana_running() { return 1; }
: >"$CALLS"; start_enable_service >/dev/null 2>&1
check "daemon-reload"        "$(grep -c 'systemctl daemon-reload' "$CALLS")" "1"
check "enable solana"        "$(grep -c 'systemctl enable solana' "$CALLS")" "1"
check "not-running -> start"      "$(grep -c 'systemctl start solana' "$CALLS")" "1"
check "NEVER restart (would reset snapshot)" "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "H1: no on-mount symlink (unit is a real /etc file, enabled by name)" "$(grep -c 'ln -sfn' "$CALLS")" "0"
# Already running -> ADOPT: enable (idempotent) but neither start NOR restart.
_start_solana_running() { return 0; }
: >"$CALLS"; ADOUT=$(start_enable_service 2>&1)
check "running -> enable still issued" "$(grep -c 'systemctl enable solana' "$CALLS")" "1"
check "running -> NO start"            "$(grep -c 'systemctl start solana' "$CALLS")" "0"
check "running -> NO restart"          "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "running -> says 'adopting'"     "$(grep -c -i 'adopting it' <<<"$ADOUT")" "1"
# The REAL probe (restore it — the branch tests above overrode it): active
# service + live agave-validator process.
unset -f _start_solana_running
# shellcheck source-path=SCRIPTDIR source=../lib/start.sh
_DEEPLOY_START_SOURCED="" source "$ROOT/lib/start.sh"   # re-source to recover the real _start_solana_running
systemctl() { case "$*" in "is-active --quiet solana") return 0;; *) echo "systemctl $*" >>"$CALLS"; return 0;; esac; }
# Mock matches the ANCHORED convention pattern the probe must pass
# ('^agave-validator --identity') — would fail if the anchor were dropped.
pgrep()     { case "$*" in *"^agave-validator --identity"*) return 0;; *) return 1;; esac; }
check_true "_start_solana_running: active+proc -> true" "_start_solana_running"
systemctl() { case "$*" in "is-active --quiet solana") return 1;; *) echo "systemctl $*" >>"$CALLS"; return 0;; esac; }
check_false "_start_solana_running: inactive -> false" "_start_solana_running"
systemctl() { echo "systemctl $*" >>"$CALLS"; return 0; }; unset -f pgrep

echo "== R10-4: catchup wait — two bounded getSlot reads, never 'solana catchup' =="
# getSlot mock: the node (127.0.0.1) answers $US, the cluster $THEM; DOWN = no
# answer (curl's exit for a refused connection). Each URL is appended to $SLOTS.
SLOTS="$WORK/slots"
curl() { local url=${!#} a; echo "$url" >>"$SLOTS"
    case "$url" in http://127.0.0.1:*) a=$US ;; *) a=$THEM ;; esac
    [[ "$a" != DOWN ]] || return 7
    printf '{"jsonrpc":"2.0","result":%s,"id":1}\n' "$a"; }
US=100 THEM=100; : >"$SLOTS"
OUT=$(CATCHUP_TIMEOUT=2 CATCHUP_INTERVAL=1 start_wait_catchup 2>&1); RC=$?
check "caught up -> 0, after one poll"        "$RC|$(wc -l <"$SLOTS" | tr -d ' ')" "0|2"
check "caught up -> says so, with both slots" "$(grep -c 'catchup: caught up (us:100 them:100)$' <<<"$OUT")" "1"
check "the wait never runs 'solana'"          "$(cat "$WORK/solana.calls" 2>/dev/null | wc -l | tr -d ' ')" "0"
US=96 THEM=100; : >"$SLOTS"
OUT=$(CATCHUP_TIMEOUT=2 CATCHUP_INTERVAL=1 start_wait_catchup 2>&1); RC=$?
check "4 behind -> caught up, 0 after one poll" "$RC|$(wc -l <"$SLOTS" | tr -d ' ')|$(grep -c 'catchup: caught up (us:96 them:100)$' <<<"$OUT")" "0|2|1"
US=10 THEM=95; : >"$SLOTS"
OUT=$(CATCHUP_TIMEOUT=1 CATCHUP_INTERVAL=1 start_wait_catchup 2>&1); RC=$?
POLLS=$(( $(wc -l <"$SLOTS") / 2 ))
check "behind past CATCHUP_TIMEOUT -> 1"      "$RC" "1"
check "a status line on every poll"           "$(( POLLS >= 1 ))|$(grep -c 'catchup: 85 slots behind (us:10 them:95) (elapsed [0-9]*s)$' <<<"$OUT")" "1|$POLLS"
DRY_RUN=1; : >"$CALLS"; : >"$SLOTS"; start_wait_catchup >/dev/null 2>&1; DRY_RUN=0
check "dry-run catchup polls nothing" "$(grep -c solana "$CALLS")|$(wc -l <"$SLOTS" | tr -d ' ')" "0|0"

echo "== R10-4: a 'solana' that prints nothing until killed — the wait still reports =="
# Through a pipe, 'solana catchup' prints nothing while the node is behind: its
# spinner is not drawn off a terminal. On the rc9 box the old wait logged
# nothing for 105 s, until the node had caught up. This stub behaves the same
# and appends its PID to $STUBS, so the test can kill it.
STUBS="$WORK/stubs"; : >"$STUBS"
printf '#!/bin/bash\necho $$ >>"%s"\nexec sleep 120\n' "$STUBS" >"$WORK/bin/solana"
# within <secs> <ERE> <cmd...>: runs <cmd> in the background and prints the
# first line of its output matching <ERE> as soon as there is one, or nothing
# after <secs>; then kills <cmd> and every stub still waiting.
within() {
    local secs=$1 re=$2 out="$WORK/within.out" pid i; shift 2
    "$@" >"$out" 2>&1 &
    pid=$!
    for (( i = 0; i < secs * 10; i++ )); do
        grep -qE "$re" "$out" && break
        command sleep 0.1
    done
    { kill -KILL "$pid"; wait "$pid"; xargs kill -KILL <"$STUBS"; } 2>/dev/null
    : >"$STUBS"
    grep -m1 -E "$re" "$out"
}
US=10 THEM=95
LINE=$(CATCHUP_INTERVAL=0 within 5 'slots behind' start_wait_catchup)
check "a status line within 5 s" "$(grep -c 'catchup: 85 slots behind (us:10 them:95)' <<<"$LINE")" "1"
printf '#!/bin/bash\necho "solana $*" >>"%s"\n' "$WORK/solana.calls" >"$WORK/bin/solana"   # the recording stub again

echo "== env-class: SOLANA_BIN resolves to an absolute path with HOME UNSET (systemd) =="
# The real-box bug: under the resume service $HOME was empty, so SOLANA_BIN
# became '/.local/.../solana/...'. start_resolve_config must derive it $HOME-free.
( unset SOLANA_BIN                                   # don't let the test's export win
  state_set solana_bin "/root/.local/share/solana/install/active_release/bin"
  HOME="" start_resolve_config
  echo "$SOLANA_BIN" ) >"$WORK/binout" 2>&1
check "SOLANA_BIN from state (HOME unset)" "$(cat "$WORK/binout")" "/root/.local/share/solana/install/active_release/bin"
check "never the empty-HOME '/.local' path"  "$(grep -c '^/\.local' "$WORK/binout")" "0"
# With no state recorded either, falls back to /root (NOT '/'), still HOME-free.
( unset SOLANA_BIN; rm -f "$DEEPLOY_STATE_DIR/state.d/solana_bin"
  HOME="" start_resolve_config
  echo "$SOLANA_BIN" ) >"$WORK/binout2" 2>&1
check "fallback base is /root, not empty HOME" "$(grep -c '^/root/.local/share/solana' "$WORK/binout2")" "1"
# restore the suite's pinned bin for later sections
export SOLANA_BIN="$WORK/bin"; start_resolve_config

echo "== set -e: the wait POLLS through failed reads (the node's RPC is not up yet) =="
# curl exits 7 (connection refused) until the node's RPC is up, as during the
# snapshot download at the start. Under main()'s exact flags (set -Eeuo
# pipefail) the poll loop must keep polling, not abort: refused twice, then
# caught up.
curl() { local url=${!#}; echo "$url" >>"$SLOTS"
    case "$url" in http://127.0.0.1:*) (( $(grep -c '^http://127\.0\.0\.1:' "$SLOTS") > 2 )) || return 7 ;; esac
    echo '{"jsonrpc":"2.0","result":100,"id":1}'; }
: >"$SLOTS"
sleep() { :; }   # don't actually wait CATCHUP_INTERVAL between polls
e_out=$( set -Eeuo pipefail; CATCHUP_TIMEOUT=2 CATCHUP_INTERVAL=0 start_wait_catchup 2>&1 ); e_rc=$?
check "the wait survives failed reads under set -Eeuo (rc 0)" "$e_rc" "0"
check "it POLLED 3x (did NOT abort on the 1st failure)"       "$(grep -c '^http://127\.0\.0\.1:' "$SLOTS")" "3"
check "each failed read is a status line"                     "$(grep -c "catchup: no slot from the node's RPC at http://127.0.0.1:8899 (elapsed" <<<"$e_out")" "2"
check "it reported caught up at the end"                      "$(grep -c 'catchup: caught up (us:100 them:100)$' <<<"$e_out")" "1"

echo "== H4: phase-8 PoH pin failure WARNS, does not abort the run (timer retries) =="
printf '#!/bin/bash\nexit 3\n' >"$WORK/failpin.sh"; chmod +x "$WORK/failpin.sh"
OUT=$( set -Eeuo pipefail; SET_POH_SCRIPT="$WORK/failpin.sh" start_pin_poh 2>&1 ); RC=$?
check    "pin failure does not abort phase 8 (rc 0)" "$RC" "0"
check_ge "pin failure surfaced as a warning"         "$(grep -ci 'did not succeed' <<<"$OUT")" "1"

echo "== final summary: hot swap with the tower (PATH form), no stdin, failover pointer =="
SUM=$(start_print_summary 2>&1)
check    "set-identity --require-tower, path form" "$(grep -c 'set-identity --require-tower /root/solana/mainnet-validator-keypair.json' <<<"$SUM")" "1"
check    "authorized-voter add path"   "$(grep -c 'authorized-voter add /root/solana/mainnet-validator-keypair.json' <<<"$SUM")" "1"
check    "NO stdin redirect form"      "$(grep -cE 'set-identity <[^a-z]' <<<"$SUM")" "0"   # '<old-…>' is a placeholder, '< file' a redirect
# R10-9: the step is called a hot swap, so it moves the tower; the cold path is
# a separate line that states its condition.
check    "old validator stops voting first"  "$(grep -c 'OLD validator first' <<<"$SUM")" "1"
check    "a restart of the old one comes back unstaked" "$(grep -c 'Make sure a restart of the OLD validator comes back unstaked' <<<"$SUM")" "1"
check    "tower copied to this ledger"       "$(grep -c 'tower-1_9-<staked-pubkey>.bin <this-box>:/root/solana/ledger/' <<<"$SUM")" "1"
check    "cold bring-up states its condition" "$(grep -c "finalized slot is at least 300 slots past the vote account's lastVote" <<<"$SUM")" "1"
check    "no bare 'No tower transfer needed'" "$(grep -c 'No tower transfer needed' <<<"$SUM")" "0"
check    "R10-6: file mode also says a restart reverts the identity" "$(grep -c 'Any restart of solana (crash, reboot, upgrade) brings this node back on the sync' <<<"$SUM")" "1"
check_ge "dz-connect mentioned (DZ on)" "$(grep -c 'dz-connect' <<<"$SUM")" "1"
# Fix #2: the printed command must be runnable — './deeploy.sh dz-connect' (or an
# absolute path via DEEPLOY_SELF), never bare 'deeploy dz-connect' (no PATH entry).
check "summary uses ./deeploy.sh dz-connect (not bare deeploy)" "$(grep -c './deeploy.sh dz-connect' <<<"$SUM")" "1"
check "summary: NO bare 'deeploy dz-connect'" "$(grep -cE '(^|[^.[:alnum:]/])deeploy dz-connect' <<<"$SUM")" "0"
check "summary: export shown as ./deeploy.sh export" "$(grep -c './deeploy.sh export' <<<"$SUM")" "1"
check_ge "failover pointer"            "$(grep -ci 'failover' <<<"$SUM")" "1"
check_ge "vote account shown"          "$(grep -c 'Vote1111' <<<"$SUM")" "1"

echo "== R10-6: offbox summary — stdin form over ssh, no staked path, the passport hint =="
OFFPK=kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu
OSUM=$(STAKED_KEY_MODE=offbox STAKED_PUBKEY="$OFFPK" STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json start_print_summary 2>&1)   # a stale path must not print
check "offbox: the key stays off this box, pubkey named" "$(grep -c "The staked key stays off this box — DeePloy knows only its pubkey ($OFFPK)" <<<"$OSUM")" "1"
check "offbox: set-identity fed on stdin over ssh"   "$(grep -c "sudo -n ${SOLANA_BIN}/agave-validator --ledger /root/solana/ledger set-identity --require-tower' < staked.json" <<<"$OSUM")" "1"
check "offbox: authorized-voter fed on stdin"        "$(grep -c "sudo -n ${SOLANA_BIN}/agave-validator --ledger /root/solana/ledger authorized-voter add' < staked.json" <<<"$OSUM")" "1"
check "offbox: a restart reverts the identity"       "$(grep -c 'brings this node back on the sync' <<<"$OSUM")" "1"
check "offbox: tower step kept"                      "$(grep -c 'tower-1_9-<staked-pubkey>.bin <this-box>:/root/solana/ledger/' <<<"$OSUM")" "1"
check "offbox: no staked keypair path, no 'Place …'" "$(grep -c 'mainnet-validator-keypair' <<<"$OSUM")|$(grep -c 'Place the real staked keypair' <<<"$OSUM")" "0|0"
check "offbox: dz-connect hint names --dz-signature" "$(grep -c -- '--dz-signature' <<<"$OSUM")" "1"
# start_resolve_config in offbox resolves no staked path, even with a stale one
# in state and another in the environment.
( state_set staked_key_mode offbox; state_set staked_keypair /stale/mainnet-validator-keypair.json
  STAKED_KEYPAIR=/env/mainnet-validator-keypair.json; start_resolve_config
  printf '%s|%s' "${STAKED_KEYPAIR:-<empty>}" "$STAKED_KEY_MODE" ) >"$WORK/srcoff" 2>/dev/null
check "offbox start_resolve_config: a stale staked path is not resolved" "$(cat "$WORK/srcoff")" "<empty>|offbox"

echo "== R1: summary distinguishes a degraded/failed finish from a real success =="
DSUM=$(start_print_summary 1 0 2>&1)   # catchup failed
check    "R1: degraded -> NOT 'synced (catchup 0)'" "$(grep -c 'synced (catchup 0)' <<<"$DSUM")" "0"
check_ge "R1: degraded -> says do NOT swap the key" "$(grep -ci 'do not swap' <<<"$DSUM")" "1"
check    "R1: degraded -> no set-identity swap cmd" "$(grep -c 'set-identity' <<<"$DSUM")" "0"
VSUM=$(start_print_summary 0 1 2>&1)   # synced, but verify reported issues
check_ge "R1: synced+verify-issues -> still 'synced'"  "$(grep -c 'synced (catchup 0)' <<<"$VSUM")" "1"
check_ge "R1: synced+verify-issues -> warns to review" "$(grep -ci 'verification' <<<"$VSUM")" "1"

echo "== R1: start_run returns non-zero on failed catchup (phase 8 not a clean success) =="
_install_verify_isolation() { return 0; }   # pass the gate
start_resolve_config() { :; }; start_precheck_disk() { :; }; start_enable_service() { :; }
start_pin_poh() { :; }; verify_run() { :; }
start_wait_catchup() { return 1; }          # catchup failed / timed out
OUT=$( ( start_run ) 2>&1 ); RC=$?
check "R1: failed catchup -> start_run non-zero"       "$RC" "1"
check "R1: failed catchup -> NOT 'synced (catchup 0)'" "$(grep -c 'synced (catchup 0)' <<<"$OUT")" "0"
unset -f _install_verify_isolation start_resolve_config start_precheck_disk start_enable_service start_pin_poh verify_run start_wait_catchup
# re-source to restore the real start_* functions the gate test below drives
_DEEPLOY_START_SOURCED="" source "$ROOT/lib/start.sh"

echo "== I1/I2: start_run is isolation-gated — every route to start fails closed on mismatch =="
# The gate calls _install_verify_isolation (declare-F guarded; defined in deeploy.sh,
# absent here). Mock it + the heavy steps to assert start_run aborts BEFORE enabling
# the service on a mismatch, and proceeds on a match.
_install_verify_isolation() { return "${ISO_RC:-0}"; }
start_resolve_config() { :; }; start_precheck_disk() { :; }
start_enable_service() { echo "ENABLE" >>"$CALLS"; }
start_wait_catchup() { :; }; start_pin_poh() { :; }; verify_run() { :; }; start_print_summary() { :; }
: >"$CALLS"; ISO_RC=1; ( start_run ) >/dev/null 2>&1; RC=$?
check "gate: mismatch -> start_run aborts"        "$RC" "1"
check "gate: mismatch -> service NEVER enabled"   "$(grep -c ENABLE "$CALLS")" "0"
: >"$CALLS"; ISO_RC=0; start_run >/dev/null 2>&1
check "gate: match -> service enabled (proceeds)" "$(grep -c ENABLE "$CALLS")" "1"
unset -f _install_verify_isolation

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
