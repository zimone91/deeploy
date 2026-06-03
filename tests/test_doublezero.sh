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
                 latency) echo "device-a 1.23ms";;
                 status)  echo "Tunnel: up";; esac; }
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

echo "== PART A (Phase 7 prepare): no connect/passport/multicast/restart/local-disconnect =="
: >"$CALLS"; printf '[1,2,3]' >"$DZ_KEYPAIR"   # operator pre-placed the DZ ID
POUT=$(DZ_ENABLED=true doublezero_run 2>&1)
check "prepare: package installed"        "$(grep -c 'apt-get install -y doublezero doublezero-solana' "$CALLS")" "1"
check "prepare: env override -> restart"  "$(grep -c 'systemctl restart doublezerod' "$CALLS")" "1"
check "prepare: doublezerod enabled boot" "$(grep -c 'systemctl enable doublezerod' "$CALLS")" "1"
check "prepare: env mainnet-beta + metrics" "$(grep -c 'env mainnet-beta -metrics-enable' "$DZ_OVERRIDE_CONF")" "1"
check "prepare: ufw GRE"                   "$(grep -c 'ufw allow proto gre' "$CALLS")" "1"
check "prepare: ufw BGP 179 (in+out)"      "$(grep -c 'on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp' "$CALLS")" "2"
check "prepare: ufw 44880 udp (in+out)"    "$(grep -c 'on doublezero0 to any port 44880 proto udp' "$CALLS")" "2"
check "prepare: ID -> ~/.config id.json"   "$(grep -c "install -m 600 $DZ_KEYPAIR $WORK/dzconfig/id.json" "$CALLS")" "1"
check "prepare: dz_prepared recorded"      "$(state_has dz_prepared && echo y || echo n)" "y"
check "prepare: dz_id recorded"            "$(state_get dz_id)" "DZid11111111111111111111111111111111111111"
# NO local 'doublezero disconnect' on the new box (no-op/error on fresh; the one
# that matters is on the OLD server, which DeePloy can't reach).
check "prepare: NO local doublezero disconnect" "$(grep -c 'doublezero disconnect' "$CALLS")" "0"
# Early heads-up (informational, NOT a gate): plan to disconnect the OLD server.
check "prepare: heads-up names OLD server"   "$(grep -c 'SAME one currently active on your OLD server' <<<"$POUT")" "1"
check "prepare: heads-up shows the commands"  "$(grep -c 'doublezero disconnect' <<<"$POUT")" "1"
check "prepare: heads-up does NOT block (rc0)" "$([[ -n "$POUT" ]] && state_has dz_prepared && echo ok || echo no)" "ok"
# the load-bearing assertion: prepare does NONE of the connect-side work
check "prepare: NO connect ibrl"           "$(grep -c 'connect ibrl' "$CALLS")" "0"
check "prepare: NO passport"               "$(grep -c 'passport' "$CALLS")" "0"
check "prepare: NO multicast"              "$(grep -c 'connect multicast' "$CALLS")" "0"
check "prepare: NO validator restart"      "$(grep -c 'systemctl restart solana' "$CALLS")" "0"

echo "== PART A: repo-swap removes an old DZ apt source before install =="
: >"$CALLS"; printf '[1,2,3]' >"$DZ_KEYPAIR"
OLDSRC="$WORK/old-doublezero.list"; : >"$OLDSRC"
# dz_install runs: find /etc/apt /usr/share/keyrings -name '*doublezero*' -print0.
# Shadow find to return our temp file (NUL-terminated) for that query.
find() { case "$*" in *-name*doublezero*-print0*) printf '%s\0' "$OLDSRC";; *) command find "$@" 2>/dev/null;; esac; }
RM_LOG="$WORK/rmlog"; : >"$RM_LOG"
rm() { echo "rm $*" >>"$RM_LOG"; command rm "$@" 2>/dev/null || true; }
DZ_APT_OK=$( DZ_ENABLED=true doublezero_run 2>&1 | grep -c 'Removing existing DZ apt source' )
check "repo-swap: warns removing old source" "$DZ_APT_OK" "1"
check "repo-swap: rm'd the old source file"  "$(grep -c "$OLDSRC" "$RM_LOG")" "1"
unset -f find rm
find() { command find "$@" 2>/dev/null; }

echo "== PART A: ID migration — absent key, interactive path entry =="
: >"$CALLS"; rm -f "$DZ_KEYPAIR" "$WORK/dzconfig/id.json"
PLACED="$WORK/elsewhere/dzid.json"; mkdir -p "$WORK/elsewhere"; printf '[4,5,6]' >"$PLACED"
ask() { REPLY="$PLACED"; }   # operator gives the path to the key
( NONINTERACTIVE=0 DZ_CLIENT_IP=203.0.113.7 dz_keypair_migrate ) >/dev/null 2>&1
check "migrate: id.json installed from given path" "$(state_get dz_id)" "DZid11111111111111111111111111111111111111"
check_true "migrate: id.json present" "[[ -f \"$WORK/dzconfig/id.json\" ]]"
unset -f ask

echo "== PART A: ID migration — absent key + non-interactive -> FAIL (no hang) =="
rm -f "$DZ_KEYPAIR" "$WORK/dzconfig/id.json"
( NONINTERACTIVE=1 dz_keypair_migrate ) >/dev/null 2>&1
check "migrate non-interactive absent -> fail" "$?" "1"

echo "== PART B (dz-connect): guarded on dz_prepared; full flow; records dz_connected =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
# not prepared yet -> fail
( dz_connect_run ) >/dev/null 2>&1; check "connect without prepare -> fail" "$?" "1"
# prepared, but staked key absent -> fail
state_set dz_prepared "$(date +%s 2>/dev/null || echo t)"; state_set dz_id "DZid11111111111111111111111111111111111111"
( dz_connect_run ) >/dev/null 2>&1; check "connect without staked key -> fail" "$?" "1"
# prepared + staked key present -> full flow. The old-server gate reads with
# `read -r reply`; shadow read to set that variable (its name arrives as $2 after -r).
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
: >"$CALLS"
read() { local v="${!#}"; eval "$v=y"; }   # answer 'y' into whatever var read targets
( NONINTERACTIVE=0 DZ_CLIENT_IP=203.0.113.7 dz_connect_run ) >/dev/null 2>&1; RC=$?
unset -f read
check "connect: full flow rc0"             "$RC" "0"
check "connect: find-validator polled"     "$(grep -c 'passport find-validator -u mainnet-beta' "$CALLS")" "1"
check "connect: passport prepare (staked)"  "$(grep -c 'prepare-validator-access .* --primary-validator-id Stakedid' "$CALLS")" "1"
check "connect: passport request +signature" "$(grep -c 'request-validator-access .* --signature SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567' "$CALLS")" "1"
check "connect: NO --backup-validator-ids (Path 1)" "$(grep -c 'backup-validator-ids' "$CALLS")" "0"
check "connect: connect ibrl --client-ip"  "$(grep -c 'connect ibrl --client-ip 203.0.113.7' "$CALLS")" "1"
check "connect: status polled"             "$(grep -c 'doublezero status' "$CALLS")" "1"
check "connect: multicast publish"         "$(grep -c 'connect multicast --publish edge-solana-shreds' "$CALLS")" "1"
check "connect: NO validator restart"      "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "connect: dz_connected recorded"     "$(state_has dz_connected && echo y || echo n)" "y"

echo "== PART B gate: OLD-server-disconnected confirmation (Option C, blocking) =="
# yes -> proceed (rc0); the gate prints the exact old-server commands
read() { local v="${!#}"; eval "$v=y"; }
GOUT=$( NONINTERACTIVE=0 dz_confirm_old_server_disconnected 2>&1 ); check "gate 'y' -> proceed (rc0)" "$?" "0"
check "gate shows 'doublezero disconnect'"   "$(grep -c 'doublezero disconnect' <<<"$GOUT")" "1"
check "gate shows stop doublezerod"          "$(grep -c 'systemctl stop doublezerod' <<<"$GOUT")" "1"
# no -> fail (does NOT connect)
read() { local v="${!#}"; eval "$v=N"; }
( NONINTERACTIVE=0 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate 'N' -> fail" "$?" "1"
# --yes does NOT bypass the gate (it's a conflict guard, not a normal confirm):
# answer N even with ASSUME_YES=1 -> still fails.
( NONINTERACTIVE=0 ASSUME_YES=1 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate ignores --yes (still needs ack)" "$?" "1"
unset -f read
# non-interactive -> FAIL with the instruction (never silently connects)
NIOUT=$( NONINTERACTIVE=1 dz_confirm_old_server_disconnected 2>&1 ); check "gate non-interactive -> fail" "$?" "1"
# grep -c is >=1 (command list + fail message); assert "at least one" by emptiness of an inverse match
check "gate non-interactive: names the OLD-server command" "$(grep -q 'doublezero disconnect' <<<"$NIOUT" && echo yes || echo no)" "yes"
# whole connect aborts non-interactively at the gate (after passport, before connect ibrl)
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
state_set dz_prepared t; state_set dz_id "DZid11111111111111111111111111111111111111"
printf '[9]' >"$WORK/mainnet-validator-keypair.json"; : >"$CALLS"
( NONINTERACTIVE=1 DZ_CLIENT_IP=203.0.113.7 dz_connect_run ) >/dev/null 2>&1; check "connect non-interactive: aborts at gate" "$?" "1"
check "connect non-interactive: did NOT connect ibrl" "$(grep -c 'connect ibrl' "$CALLS")" "0"
check "connect non-interactive: did NOT record dz_connected" "$(state_has dz_connected && echo y || echo n)" "n"

echo "== PART B: find-validator POLLS (not-in-schedule then in-schedule) =="
ATT="$WORK/findatt"; : >"$ATT"
doublezero-solana() { echo "doublezero-solana $*" >>"$CALLS"
    case "$*" in *find-validator*) echo x >>"$ATT"; if [[ "$(wc -l <"$ATT")" -lt 3 ]]; then echo "gossip: no; not yet";
                 else echo "In Leader scheduler: yes"; fi;; esac; }
_dz_await_in_leader_schedule >/dev/null 2>&1
check "find-validator polled until in-schedule (3 tries)" "$(wc -l <"$ATT" | tr -d ' ')" "3"
# restore the simple mock
doublezero-solana(){ echo "doublezero-solana $*" >>"$CALLS"; case "$*" in *find-validator*) echo "In Leader scheduler: yes";; esac; }

echo "== dz_resume: no-op until dz_connected; verify/restore once connected =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set dz_prepared t   # prepared but NOT connected
: >"$CALLS"
RES=$(dz_resume 2>&1); check "resume no-op when not connected -> rc0" "$?" "0"
check "resume no-op: nothing connected"   "$(grep -c 'connect ibrl' "$CALLS")" "0"
check "resume no-op: says nothing to restore" "$(grep -c 'nothing to restore' <<<"$RES")" "1"
# connected + iface up -> verify only
state_set dz_connected t; state_set dz_client_ip 203.0.113.7
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 0;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+up: no reconnect" "$(grep -c 'connect ibrl' "$CALLS")" "0"
# connected + iface down -> restore
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 1;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+down: reconnects" "$(grep -c 'connect ibrl' "$CALLS")" "1"
check "resume NEVER re-places a key"      "$(grep -c 'install -m 600' "$CALLS")" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
