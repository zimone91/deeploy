#!/usr/bin/env bash
# Self-contained tests for lib/start.sh — systemctl/solana/df mocked.
# Covers the disk precheck, enable+start, catchup-wait, and the final summary
# (set-identity PATH form, no stdin form, failover pointer).
#
# Mocks shadow real commands and are invoked indirectly.
# The catchup mock is printf'd as a script with literal $(...) / $n on purpose.
# shellcheck disable=SC2329,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
mkdir -p "$WORK/bin"
printf '#!/bin/bash\necho "0 slot(s) behind (us:100 them:100)"\n' >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"
export SOLANA_BIN="$WORK/bin"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/start.sh
source "$ROOT/lib/start.sh"

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
_start_free_gb() { echo 1800; }

echo "== enable + start: IDEMPOTENT (adopt a running node; never restart mid-snapshot) =="
# Not running -> enable + START (not restart). _start_solana_running false.
_start_solana_running() { return 1; }
: >"$CALLS"; start_enable_service >/dev/null 2>&1
check "daemon-reload"        "$(grep -c 'systemctl daemon-reload' "$CALLS")" "1"
check "enable solana"        "$(grep -c 'systemctl enable solana' "$CALLS")" "1"
check "not-running -> start"      "$(grep -c 'systemctl start solana' "$CALLS")" "1"
check "NEVER restart (would reset snapshot)" "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "symlink unit"         "$(grep -c 'ln -sfn /root/solana/solana.service /etc/systemd/system/solana.service' "$CALLS")" "1"
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

echo "== catchup wait (mock 'caught up' immediately) =="
start_wait_catchup >/dev/null 2>&1; check "catchup returns 0 when caught up" "$?" "0"
printf '#!/bin/bash\necho "120 slot(s) behind"\n' >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"
CATCHUP_TIMEOUT=1 CATCHUP_INTERVAL=1 start_wait_catchup >/dev/null 2>&1; check "catchup times out -> 1" "$?" "1"
printf '#!/bin/bash\necho "0 slot(s) behind"\n' >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"
DRY_RUN=1; : >"$CALLS"; start_wait_catchup >/dev/null 2>&1; DRY_RUN=0
check "dry-run catchup polls nothing" "$(grep -c solana "$CALLS")" "0"

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
export SOLANA_BIN="$WORK/bin"; printf '#!/bin/bash\necho "0 slot(s) behind"\n' >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"; start_resolve_config

echo "== set -e: catchup loop POLLS through non-zero catchup (the real-box scenario) =="
# 'solana catchup' returns NON-ZERO the whole time the node is behind (normal
# mid-sync). Under main()'s exact flags (set -Eeuo pipefail) the poll loop must
# keep polling, not abort. Mock: behind (exit 1) twice, then caught up (exit 0).
CC="$WORK/cc"; : >"$CC"
printf '#!/bin/bash\necho c >> "%s"\nn=$(wc -l < "%s")\nif [ "$n" -lt 3 ]; then echo "$((90 - n*10)) slot(s) behind (us:1 them:99)"; exit 1; fi\necho "0 slot(s) behind (us:100 them:100)"; exit 0\n' "$CC" "$CC" >"$WORK/bin/solana"
chmod +x "$WORK/bin/solana"
sleep() { :; }   # don't actually wait CATCHUP_INTERVAL between polls
e_out=$( set -Eeuo pipefail; CATCHUP_INTERVAL=0 start_wait_catchup 2>&1 ); e_rc=$?
check "catchup loop survives non-zero catchup under set -Eeuo (rc 0)" "$e_rc" "0"
check "loop POLLED 3x (did NOT abort on the 1st non-zero)"            "$(wc -l <"$CC" | tr -d ' ')" "3"
check "loop reported caught up at the end"                            "$(grep -c 'Caught up' <<<"$e_out")" "1"

echo "== final summary: set-identity PATH form, no stdin, failover pointer =="
SUM=$(start_print_summary 2>&1)
check    "set-identity path form"      "$(grep -c 'set-identity /root/solana/mainnet-validator-keypair.json' <<<"$SUM")" "1"
check    "authorized-voter add path"   "$(grep -c 'authorized-voter add /root/solana/mainnet-validator-keypair.json' <<<"$SUM")" "1"
check    "NO stdin redirect form"      "$(grep -c 'set-identity <' <<<"$SUM")" "0"
check_ge "tower-rebuild note"          "$(grep -ci 'tower' <<<"$SUM")" "1"
check_ge "dz-connect mentioned (DZ on)" "$(grep -c 'dz-connect' <<<"$SUM")" "1"
# Fix #2: the printed command must be runnable — './deeploy.sh dz-connect' (or an
# absolute path via DEEPLOY_SELF), never bare 'deeploy dz-connect' (no PATH entry).
check "summary uses ./deeploy.sh dz-connect (not bare deeploy)" "$(grep -c './deeploy.sh dz-connect' <<<"$SUM")" "1"
check "summary: NO bare 'deeploy dz-connect'" "$(grep -cE '(^|[^.[:alnum:]/])deeploy dz-connect' <<<"$SUM")" "0"
check "summary: export shown as ./deeploy.sh export" "$(grep -c './deeploy.sh export' <<<"$SUM")" "1"
check_ge "failover pointer"            "$(grep -ci 'failover' <<<"$SUM")" "1"
check_ge "vote account shown"          "$(grep -c 'Vote1111' <<<"$SUM")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
