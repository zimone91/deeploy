#!/usr/bin/env bash
# Self-contained tests for lib/doublezero.sh — no network, no DZ daemon.
# DoubleZero is now TWO parts:
#   PART A (Phase 7 prepare): install (repo-swap) / env+metrics / ufw(GRE,BGP,44880)
#     / ID-migration / latency / disconnect / enabled-on-boot — NO connect/passport/
#     multicast/restart.
#   PART B (dz-connect, post-swap): find-validator poll -> passport (staked key) ->
#     connect ibrl -> status poll -> multicast. Guarded on dz_prepared; records
#     dz_connected.
# Plus dz_should_enable precedence and dz_resume (no-op until dz_connected).
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

mkdir -p "$WORK/bin"
export KEYGENLOG="$WORK/keygen.log"; : >"$KEYGENLOG"
cat >"$WORK/bin/solana-keygen" <<'EOF'
#!/bin/bash
case "$1" in
  pubkey) case "$2" in *mainnet-validator-keypair*) echo "Stakedid111111111111111111111111111111111";; *) echo "Other11111111111111111111111111111111111111";; esac ;;
esac
EOF
cat >"$WORK/bin/solana" <<'EOF'
#!/bin/bash
case "$1" in sign-offchain-message) echo "SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567";; esac
EOF
chmod +x "$WORK/bin/solana-keygen" "$WORK/bin/solana"
export SOLANA_BIN="$WORK/bin"
export DZ_KEYPAIR="$WORK/dz-keypair.json"
export DZ_CONFIG_DIR="$WORK/dzconfig"
export DZ_OVERRIDE_CONF="$WORK/override.conf"
# Fast polls in tests.
export DZ_FIND_RETRIES=5 DZ_FIND_INTERVAL=0 DZ_STATUS_RETRIES=5 DZ_STATUS_INTERVAL=0 DZ_LATENCY_RETRIES=2 DZ_LATENCY_INTERVAL=0

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/doublezero.sh
source "$ROOT/lib/doublezero.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
require_root()    { :; }
sleep()           { :; }
doublezero()      { echo "doublezero $*" >>"$CALLS"
    case "$*" in address) echo "DZid11111111111111111111111111111111111111";;
                 latency) printf '%s\n' ' Code | Avg | reachable ' ' dz-syn1-sw01 | 0.24 ms | true ';;
                 status)  printf '%s\n' \
                     ' Tunnel Status | Tunnel Name | Current Device | Metro | Multicast Groups ' \
                     ' BGP Session Up | doublezero0 | dz-syn1-sw01 | metro-a | ' \
                     ' BGP Session Up | doublezero1 | dz-syn1-sw01 | metro-a | P:edge-solana-shreds ';; esac; }
doublezero-solana(){ echo "doublezero-solana $*" >>"$CALLS"
    case "$*" in *find-validator*) echo "validator gossip: yes; In Leader scheduler: yes";; esac; }
ufw()             { echo "ufw $*" >>"$CALLS"; }
systemctl()       { echo "systemctl $*" >>"$CALLS"; }
apt-get()         { echo "apt-get $*" >>"$CALLS"; }
install()         { echo "install $*" >>"$CALLS"; command install "$@" 2>/dev/null || true; }
ip()              { case "$*" in *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; *"link show"*) return 0;; *) echo x;; esac; }
curl()            { local i j o=""; for ((i=1;i<=$#;i++)); do [[ "${!i}" == "-o" ]] && { j=$((i+1)); o="${!j}"; }; done; [[ -n "$o" ]] && : >"$o"; echo "curl $*" >>"$CALLS"; }
find()            { command find "$@" 2>/dev/null; }

state_set solana_home /root/solana
state_set staked_keypair "$WORK/mainnet-validator-keypair.json"

echo "== dz_should_enable: env > state > prompt; --yes does NOT enable =="
( DZ_ENABLED=true  dz_should_enable ) >/dev/null 2>&1; check "env=true -> enable (rc0)" "$?" "0"
( DZ_ENABLED=false dz_should_enable ) >/dev/null 2>&1; check "env=false -> skip (rc1)"  "$?" "1"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; state_set dz_enabled true
( unset DZ_ENABLED; dz_should_enable ) >/dev/null 2>&1; check "state=true honored" "$?" "0"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
# clear recorded state so the prompt path (not the state path) is exercised
clrdz() { rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; }
clrdz; ( unset DZ_ENABLED; NONINTERACTIVE=1 dz_should_enable ) >/dev/null 2>&1; check "unset+non-interactive -> skip" "$?" "1"
clrdz; ( unset DZ_ENABLED; ASSUME_YES=1 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "unset+--yes -> skip (no auto-enable)" "$?" "1"
ask() { REPLY=y; }; clrdz; ( unset DZ_ENABLED; ASSUME_YES=0 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "interactive 'y' -> enable" "$?" "0"
ask() { REPLY=N; }; clrdz; ( unset DZ_ENABLED; ASSUME_YES=0 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "interactive 'N' -> skip" "$?" "1"
unset -f ask
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"

echo "== Phase 7 (install) = no-op pointer (prepare moved to Phase 1) =="
: >"$CALLS"
POUT=$(doublezero_run 2>&1)
check "phase7: points to dz-connect"   "$(grep -c 'deeploy dz-connect' <<<"$POUT")" "1"
check "phase7: NO install/connect/passport here" "$(grep -cE 'apt-get|connect ibrl|passport' "$CALLS")" "0"

echo "== Phase 5 SOFT keypair check: found / path-given-copies / absent-warns-not-blocks =="
DZ_SOFT_KP="$WORK/soft-dz.json"; state_set dz_enabled true; state_set dz_keypair "$DZ_SOFT_KP"
# present -> ok
printf '[1,2,3]' >"$DZ_SOFT_KP"; : >"$CALLS"
( DZ_KEYPAIR="$DZ_SOFT_KP" dz_keypair_check_soft ) >/dev/null 2>&1; check "soft: present -> rc0" "$?" "0"
# absent + path given -> copies to standard path, still non-blocking
rm -f "$DZ_SOFT_KP"; ELSE="$WORK/else-dz.json"; printf '[7]' >"$ELSE"
ask() { REPLY="$ELSE"; }
( DZ_KEYPAIR="$DZ_SOFT_KP" NONINTERACTIVE=0 dz_keypair_check_soft ) >/dev/null 2>&1; SRC_RC=$?
unset -f ask
check "soft: path-given -> rc0 (non-block)" "$SRC_RC" "0"
check_true "soft: copied to standard path"  "[[ -f \"$DZ_SOFT_KP\" ]]"
# absent + nothing placed -> WARNS but does NOT block (rc0)
rm -f "$DZ_SOFT_KP"
SOFTOUT=$( DZ_KEYPAIR="$DZ_SOFT_KP" NONINTERACTIVE=1 dz_keypair_check_soft 2>&1 ); check "soft: absent non-interactive -> rc0 (non-block)" "$?" "0"
check "soft: absent -> WARNS to place before dz-connect" "$(grep -c 'place it before' <<<"$SOFTOUT")" "1"
# gated: dz_enabled=false -> no-op rc0
state_set dz_enabled false; ( dz_keypair_check_soft ) >/dev/null 2>&1; check "soft: dz_enabled=false -> no-op rc0" "$?" "0"
state_set dz_enabled true

echo "== dz-connect GUARD: enabled + binaries installed + staked key (replaces dz_prepared) =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
# not enabled -> fail
( dz_connect_run ) >/dev/null 2>&1; check "connect not-enabled -> fail" "$?" "1"
state_set dz_enabled true
# enabled but binaries NOT installed -> fail (the dz_prepared-replacement check).
# have() resolves via PATH; with doublezero mocked as a FUNCTION, `have` (command -v)
# still finds it, so simulate "not installed" by making have() report absent.
have() { case "$1" in doublezero|doublezero-solana) return 1;; *) command -v "$1" >/dev/null 2>&1;; esac; }
GUARDOUT=$( dz_connect_run 2>&1 ); check "connect enabled+not-installed -> fail" "$?" "1"
check "connect not-installed: clear message" "$(grep -c "not installed" <<<"$GUARDOUT")" "1"
# restore real have() behavior (do NOT unset -f: that would delete common.sh's
# real have, breaking the guard's `have doublezero` in later tests). The DZ cmds
# are mocked as functions, so command -v finds them -> guard passes.
have() { command -v "$1" >/dev/null 2>&1; }
# enabled + installed but staked key absent -> fail
rm -f "$WORK/mainnet-validator-keypair.json"
( dz_connect_run ) >/dev/null 2>&1; check "connect no staked key -> fail" "$?" "1"

echo "== dz-connect FULL flow: hard-migrate -> find -> gate -> passport -> connect -> multicast -> displays =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
state_set dz_enabled true
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
printf '[1,2,3]' >"$DZ_KEYPAIR"          # DZ ID placed (hard migrate will install it)
rm -f "$WORK/dzconfig/id.json"
: >"$CALLS"
read() { local v="${!#}"; eval "$v=y"; }  # old-server gate ack
( NONINTERACTIVE=0 DZ_CLIENT_IP=203.0.113.7 dz_connect_run ) >/dev/null 2>&1; RC=$?
unset -f read
check "connect: full flow rc0"               "$RC" "0"
check "connect: hard-migrate installed id.json" "$(grep -c "install -m 600 $DZ_KEYPAIR $WORK/dzconfig/id.json" "$CALLS")" "1"
check "connect: find-validator polled"       "$(grep -c 'passport find-validator -u mainnet-beta' "$CALLS")" "1"
check "connect: passport prepare (staked)"   "$(grep -c 'prepare-validator-access .* --primary-validator-id Stakedid' "$CALLS")" "1"
check "connect: passport request +signature" "$(grep -c 'request-validator-access .* --signature SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567' "$CALLS")" "1"
check "connect: NO --backup-validator-ids (Path 1)" "$(grep -c 'backup-validator-ids' "$CALLS")" "0"
check "connect: connect ibrl --client-ip"    "$(grep -c 'connect ibrl --client-ip 203.0.113.7' "$CALLS")" "1"
check "connect: multicast publish"           "$(grep -c 'connect multicast --publish edge-solana-shreds' "$CALLS")" "1"
check "connect: latency display ran"         "$(grep -c 'doublezero latency' "$CALLS")" "1"
check "connect: status display ran"          "$(grep -c 'doublezero status' "$CALLS")" "1"
check "connect: NO validator restart"        "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "connect: dz_connected recorded"       "$(state_has dz_connected && echo y || echo n)" "y"

echo "== dz-connect GATE: --yes ignored, non-interactive aborts before connect ibrl =="
read() { local v="${!#}"; eval "$v=N"; }
GOUT=$( NONINTERACTIVE=0 dz_confirm_old_server_disconnected 2>&1 ); check "gate 'N' -> fail" "$?" "1"
check "gate shows old-server commands" "$(grep -c 'doublezero disconnect' <<<"$GOUT")" "1"
( NONINTERACTIVE=0 ASSUME_YES=1 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate ignores --yes (answered N)" "$?" "1"
unset -f read
NIOUT=$( NONINTERACTIVE=1 dz_confirm_old_server_disconnected 2>&1 ); check "gate non-interactive -> fail" "$?" "1"
check "gate non-interactive: names old-server cmd" "$(grep -q 'doublezero disconnect' <<<"$NIOUT" && echo yes || echo no)" "yes"

echo "== display parsers: latency nearest device + status two-tunnel verdict (synthetic fixture, real shape) =="
LAT=$(printf '%s\n' \
  ' Pubkey | Code        | IP        | Min  | Max  | Avg    | reachable ' \
  ' pk1    | dz-syn2-sw01 | 1.2.3.4  | 9.1  | 9.9  | 9.40 ms| true ' \
  ' pk2    | dz-syn1-sw01 | 5.6.7.8  | 0.2  | 0.3  | 0.24 ms| true ')
check "latency: nearest = lowest Avg (syn1 0.24)" "$(printf '%s\n' "$LAT" | _dz_parse_latency_nearest)" "dz-syn1-sw01 0.24"
STATUS=$(printf '%s\n' \
  ' Tunnel Status  | Tunnel Name | User Type | Current Device | Metro   | Network      | Multicast Groups ' \
  ' BGP Session Up | doublezero0 | IBRL      | dz-syn1-sw01   | metro-a | mainnet-beta | ' \
  ' BGP Session Up | doublezero1 | Multicast | dz-syn1-sw01   | metro-a | mainnet-beta | P:edge-solana-shreds ')
check "status: doublezero0 Tunnel Status"  "$(printf '%s\n' "$STATUS" | _dz_status_field doublezero0 'Tunnel Status')" "BGP Session Up"
check "status: doublezero0 Current Device" "$(printf '%s\n' "$STATUS" | _dz_status_field doublezero0 'Current Device')" "dz-syn1-sw01"
check "status: doublezero0 Metro"          "$(printf '%s\n' "$STATUS" | _dz_status_field doublezero0 'Metro')" "metro-a"
check "status: doublezero1 Multicast Groups" "$(printf '%s\n' "$STATUS" | _dz_status_field doublezero1 'Multicast Groups')" "P:edge-solana-shreds"
# the success-verdict logic over the parsed fixture (IBRL + Multicast both up, group present)
IBRL=$(printf '%s\n' "$STATUS" | _dz_status_field doublezero0 'Tunnel Status')
MC=$(printf '%s\n' "$STATUS"   | _dz_status_field doublezero1 'Tunnel Status')
MG=$(printf '%s\n' "$STATUS"   | _dz_status_field doublezero1 'Multicast Groups')
check_true "status: success verdict holds" "[[ \"$IBRL\" == *'BGP Session Up'* && \"$MC\" == *'BGP Session Up'* && \"$MG\" == *edge-solana-shreds* ]]"
# a NOT-up case (doublezero0 down) must not read as success
STATUS_BAD=$(printf '%s\n' \
  ' Tunnel Status | Tunnel Name | Current Device | Metro | Multicast Groups ' \
  ' Down          | doublezero0 | dz-syn1-sw01   | metro-a | ')
check "status: down tunnel not 'BGP Session Up'" "$(printf '%s\n' "$STATUS_BAD" | _dz_status_field doublezero0 'Tunnel Status')" "Down"

echo "== dz_resume: gated on dz_connected (NOT dz_enabled); no-op until connected =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set dz_enabled true   # enabled but NOT connected
: >"$CALLS"
RES=$(dz_resume 2>&1); check "resume no-op when not connected -> rc0" "$?" "0"
check "resume no-op: nothing connected"        "$(grep -c 'connect ibrl' "$CALLS")" "0"
check "resume no-op: says nothing to restore"  "$(grep -c 'nothing to restore' <<<"$RES")" "1"
# connected + iface up -> verify only
state_set dz_connected t; state_set dz_client_ip 203.0.113.7
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 0;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+up: no reconnect"      "$(grep -c 'connect ibrl' "$CALLS")" "0"
# connected + iface down -> restore
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 1;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+down: reconnects"      "$(grep -c 'connect ibrl' "$CALLS")" "1"
check "resume NEVER re-places a key"           "$(grep -c 'install -m 600' "$CALLS")" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
