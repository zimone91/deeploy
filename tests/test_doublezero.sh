#!/usr/bin/env bash
# Self-contained tests for lib/doublezero.sh — no network, no DZ daemon.
# doublezero/doublezero-solana/ufw/systemctl/apt-get/curl/ip and a mock
# solana(-keygen) under $SOLANA_BIN are used. Focus: GRE-before / BGP-after
# ordering, official UFW form, multicast conditional, deferred finalize, and the
# dz-finalize staked-key gate.
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

# Mock solana toolchain under SOLANA_BIN.
mkdir -p "$WORK/bin"
export KEYGENLOG="$WORK/keygen.log"; : >"$KEYGENLOG"
cat >"$WORK/bin/solana-keygen" <<'EOF'
#!/bin/bash
case "$1" in
  new) prev=""; out=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done; echo "[1,2,3]" >"$out"; echo "new $out" >>"$KEYGENLOG" ;;
  pubkey) case "$2" in *dz-keypair*) echo "DZaddr1111111111111111111111111111111111111";;
                       *mainnet-validator-keypair*) echo "Stakedid111111111111111111111111111111111";;
                       *) echo "Other11111111111111111111111111111111111111";; esac ;;
esac
EOF
# sign-offchain-message prints the signature as the last line (a lone base58 string)
cat >"$WORK/bin/solana" <<'EOF'
#!/bin/bash
case "$1" in sign-offchain-message) echo "SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567";; esac
EOF
chmod +x "$WORK/bin/solana-keygen" "$WORK/bin/solana"
export SOLANA_BIN="$WORK/bin"
export DZ_KEYPAIR="$WORK/dz-keypair.json"
export DZ_CONFIG_DIR="$WORK/dzconfig"
export DZ_OVERRIDE_CONF="$WORK/override.conf"

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
doublezero()      { echo "doublezero $*" >>"$CALLS"; }
doublezero-solana(){ echo "doublezero-solana $*" >>"$CALLS"; }
ufw()             { echo "ufw $*" >>"$CALLS"; }
systemctl()       { echo "systemctl $*" >>"$CALLS"; }
apt-get()         { echo "apt-get $*" >>"$CALLS"; }
ip()              { echo "1.1.1.1 via 10.0.0.1 dev eth0 src 203.0.113.7"; }
cp()              { echo "cp $*" >>"$CALLS"; command cp "$@" 2>/dev/null || true; }
curl()            { local i j o=""; for ((i=1;i<=$#;i++)); do [[ "${!i}" == "-o" ]] && { j=$((i+1)); o="${!j}"; }; done; [[ -n "$o" ]] && : >"$o"; echo "curl $*" >>"$CALLS"; }

state_set solana_home /root/solana
state_set staked_keypair "$WORK/mainnet-validator-keypair.json"

echo "== _dz_valid_ip / public-ip detection =="
check_true  "valid ip"        "_dz_valid_ip 203.0.113.7"
check_false "octet > 255"     "_dz_valid_ip 1.2.3.999"
check_false "not an ip"       "_dz_valid_ip nope"
check "detect from ip route src" "$(_dz_detect_public_ip)" "203.0.113.7"

echo "== full deploy flow: ORDER (GRE before connect, BGP after) =="
: >"$CALLS"; rm -f "$DZ_KEYPAIR"
# This block exercises ordering/UFW/multicast, not the migration gate -> fresh key.
DZ_KEY_MODE=fresh DZ_CLIENT_IP=203.0.113.7 DZ_MULTICAST=true ASSUME_YES=1 doublezero_run >/dev/null 2>&1
GRELN=$(grep -n 'ufw allow proto gre' "$CALLS" | head -1 | cut -d: -f1)
CONLN=$(grep -n 'doublezero connect ibrl' "$CALLS" | head -1 | cut -d: -f1)
BGPLN=$(grep -n 'ufw allow in on doublezero0' "$CALLS" | head -1 | cut -d: -f1)
check_true "GRE rule BEFORE connect ibrl"  "[[ ${GRELN:-0} -lt ${CONLN:-0} ]]"
check_true "BGP rules AFTER connect ibrl"  "[[ ${BGPLN:-0} -gt ${CONLN:-0} ]]"

echo "== official UFW form (not before.rules, not global 179/tcp) =="
check "GRE allow proto gre"          "$(grep -c 'ufw allow proto gre from any to any' "$CALLS")" "1"
check "BGP in/out on doublezero0"    "$(grep -c 'on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp' "$CALLS")" "2"
check "NO global allow 179/tcp"      "$(grep -c 'ufw allow 179/tcp' "$CALLS")" "0"

echo "== env override + connect + multicast =="
check "override env mainnet-beta"    "$(grep -c 'env mainnet-beta' "$DZ_OVERRIDE_CONF")" "1"
check "config set env"               "$(grep -c 'doublezero config set --env mainnet-beta' "$CALLS")" "1"
check "connect ibrl --client-ip"     "$(grep -c 'doublezero connect ibrl --client-ip 203.0.113.7' "$CALLS")" "1"
check "multicast publish (on)"       "$(grep -c 'doublezero connect multicast --publish edge-solana-shreds' "$CALLS")" "1"
check "id.json copied to config dir" "$(grep -c "cp $WORK/dz-keypair.json $WORK/dzconfig/id.json" "$CALLS")" "1"

echo "== deploy DEFERS staked-key steps =="
check "no passport at deploy"          "$(grep -c 'passport' "$CALLS")" "0"
check "no validator-deposit at deploy" "$(grep -c 'validator-deposit' "$CALLS")" "0"

echo "== multicast OFF -> no publish =="
: >"$CALLS"
# key already present from the prior flow -> migration auto-passes (valid + ASSUME_YES); fresh would refuse to clobber
DZ_KEY_MODE=migration DZ_CLIENT_IP=203.0.113.7 DZ_MULTICAST=false ASSUME_YES=1 doublezero_run >/dev/null 2>&1
check "no multicast publish when off" "$(grep -c 'connect multicast' "$CALLS")" "0"

echo "== dz_keypair: FRESH mode generates (no key present) =="
: >"$CALLS"; rm -f "$DZ_KEYPAIR"; : >"$KEYGENLOG"
DZ_CLIENT_IP=203.0.113.7 dz_resolve_config >/dev/null 2>&1
DZ_KEY_MODE=fresh dz_keypair >/dev/null 2>&1
check_true "fresh: dz-keypair generated" "[[ -f \"$DZ_KEYPAIR\" ]]"
check "fresh: keygen invoked once"       "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "1"

echo "== dz_keypair: FRESH refuses to clobber an existing key =="
: >"$KEYGENLOG"   # key now exists from the previous block
( DZ_KEY_MODE=fresh dz_keypair ) >/dev/null 2>&1
check "fresh + existing key -> fail (no clobber)" "$?" "1"
check "fresh refusal: keygen NOT invoked"         "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "0"

echo "== dz_keypair: MIGRATION with key already present -> warns + gates, never regenerates =="
: >"$KEYGENLOG"
MOUT=$(DZ_KEY_MODE=migration ASSUME_YES=1 dz_keypair 2>&1)
check "migration: disconnect shown"     "$(grep -c 'doublezero disconnect' <<<"$MOUT")" "1"
check "migration: stop doublezerod"     "$(grep -c 'systemctl stop doublezerod' <<<"$MOUT")" "1"
check "migration: disable doublezerod"  "$(grep -c 'systemctl disable doublezerod' <<<"$MOUT")" "1"
check "migration: NOT regenerated"      "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "0"
( DZ_KEY_MODE=migration dz_keypair ) >/dev/null 2>&1   # ASSUME_YES=0, non-interactive -> confirm N -> fail
check "migration decline old-server -> fail" "$?" "1"

echo "== dz_keypair: MIGRATION key-absent-then-placed (interactive wait loop) =="
rm -f "$DZ_KEYPAIR"; : >"$KEYGENLOG"
# Simulate the operator: first 'ask' fires while the key is missing; our stubbed
# ask PLACES the key (as if done in another shell) then returns, so the loop's
# re-check finds it. confirm() returns 0 (old server stopped). Force interactive.
ask()     { printf '[7,7,7]' >"$DZ_KEYPAIR"; REPLY=""; }   # places key on the blocking prompt
confirm() { return 0; }
WAITOUT=$( NONINTERACTIVE=0 DZ_KEY_MODE=migration dz_keypair 2>&1 ); WRC=$?
check "migration wait: succeeds once key placed" "$WRC" "0"
check "migration wait: 'Place your existing' shown" "$(grep -c 'Place your existing dz-keypair' <<<"$WAITOUT")" "1"
check "migration wait: key NOT regenerated"      "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "0"
check_true "migration wait: key now present"     "[[ -f \"$DZ_KEYPAIR\" ]]"
unset -f ask confirm

echo "== dz_keypair: MIGRATION rejects an INVALID placed key, then accepts a valid one =="
: >"$KEYGENLOG"
printf 'not-a-keypair' >"$DZ_KEYPAIR"     # invalid: solana-keygen pubkey fails on it
# Mock keygen pubkey to fail for THIS garbage file but succeed once it's replaced.
cat >"$WORK/bin/solana-keygen" <<'EOF'
#!/bin/bash
case "$1" in
  pubkey) if grep -q 'not-a-keypair' "$2" 2>/dev/null; then exit 1; fi
          echo "DZaddr1111111111111111111111111111111111111" ;;
  new) prev=""; out=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done; echo "[1,2,3]" >"$out"; echo "new $out" >>"$KEYGENLOG" ;;
esac
EOF
chmod +x "$WORK/bin/solana-keygen"
ask()     { printf '[8,8,8]' >"$DZ_KEYPAIR"; REPLY=""; }   # replaces garbage with a valid key
confirm() { return 0; }
IOUT=$( NONINTERACTIVE=0 DZ_KEY_MODE=migration dz_keypair 2>&1 ); IRC=$?
check "migration: invalid key rejected then valid accepted" "$IRC" "0"
check "migration: 'not a readable Solana keypair' warned"   "$(grep -c 'not a readable Solana keypair' <<<"$IOUT")" "1"
unset -f ask confirm
# restore the standard keygen mock for any later use
cat >"$WORK/bin/solana-keygen" <<'EOF'
#!/bin/bash
case "$1" in
  new) prev=""; out=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done; echo "[1,2,3]" >"$out"; echo "new $out" >>"$KEYGENLOG" ;;
  pubkey) case "$2" in *dz-keypair*) echo "DZaddr1111111111111111111111111111111111111";;
                       *mainnet-validator-keypair*) echo "Stakedid111111111111111111111111111111111";;
                       *) echo "Other11111111111111111111111111111111111111";; esac ;;
esac
EOF
chmod +x "$WORK/bin/solana-keygen"

echo "== dz_keypair: MIGRATION non-interactive + key absent -> FAIL (no hang, no generate) =="
rm -f "$DZ_KEYPAIR"; : >"$KEYGENLOG"
( NONINTERACTIVE=1 DZ_KEY_MODE=migration dz_keypair ) >/dev/null 2>&1
check "migration non-interactive absent-key -> fail" "$?" "1"
check "migration non-interactive: did NOT generate"  "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "0"
check_false "migration non-interactive: no key created" "[[ -f \"$DZ_KEYPAIR\" ]]"

echo "== dz-finalize: gated on staked key; passport ONLY (no deposit) =="
: >"$CALLS"
( state_set staked_keypair /nonexistent; DZ_CLIENT_IP=203.0.113.7 dz_finalize_run ) >/dev/null 2>&1
check "finalize fails without staked key" "$?" "1"
state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
: >"$CALLS"
DZ_CLIENT_IP=203.0.113.7 dz_finalize_run >/dev/null 2>&1
check "passport prepare"                   "$(grep -c 'passport prepare-validator-access' "$CALLS")" "1"
check "sign chained -> request --signature" "$(grep -c 'passport request-validator-access .* --signature SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567' "$CALLS")" "1"
check "NO validator-deposit (removed)"     "$(grep -c 'validator-deposit' "$CALLS")" "0"

echo "== dz_should_enable: env > state > prompt; --yes does NOT enable =="
# env explicitly set -> honored, no prompt, recorded to state
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( DZ_ENABLED=true  dz_should_enable ) >/dev/null 2>&1; check "env=true -> enable (rc0)"  "$?" "0"
( DZ_ENABLED=false dz_should_enable ) >/dev/null 2>&1; check "env=false -> skip (rc1)"   "$?" "1"
DZ_ENABLED=true dz_should_enable >/dev/null 2>&1
check "decision recorded to state" "$(state_get dz_enabled)" "true"
# recorded state honored when env unset (resume: no re-prompt)
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; state_set dz_enabled true
( unset DZ_ENABLED; dz_should_enable ) >/dev/null 2>&1; check "state=true honored -> enable" "$?" "0"
# unset + non-interactive -> skip (NEVER hangs/enables)
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( unset DZ_ENABLED; NONINTERACTIVE=1 dz_should_enable ) >/dev/null 2>&1; check "unset+non-interactive -> skip" "$?" "1"
# unset + --yes -> skip (per decision: --yes does NOT auto-enable DZ)
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( unset DZ_ENABLED; ASSUME_YES=1 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "unset+--yes -> skip (no auto-enable)" "$?" "1"
# unset + interactive 'y' -> enable
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
ask() { REPLY=y; }
( unset DZ_ENABLED; ASSUME_YES=0 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "unset+interactive 'y' -> enable" "$?" "0"
ask() { REPLY=N; }
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( unset DZ_ENABLED; ASSUME_YES=0 NONINTERACTIVE=0 dz_should_enable ) >/dev/null 2>&1; check "unset+interactive 'N' -> skip" "$?" "1"
unset -f ask

echo "== multicast sub-prompt (resolve_config): preset > state > prompt =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; state_set solana_home /root/solana
ask() { case "$1" in *multicast*) REPLY=y;; *Public\ IP*) REPLY=203.0.113.7;; *) REPLY="";; esac; }
( unset DZ_MULTICAST; ASSUME_YES=0 NONINTERACTIVE=0 DZ_CLIENT_IP=203.0.113.7 dz_resolve_config >/dev/null 2>&1; [[ "$DZ_MULTICAST" == "true" ]] )
check "multicast prompt 'y' -> true" "$?" "0"
ask() { REPLY=""; }   # empty -> default N
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; state_set solana_home /root/solana
( unset DZ_MULTICAST; ASSUME_YES=0 NONINTERACTIVE=0 DZ_CLIENT_IP=203.0.113.7 dz_resolve_config >/dev/null 2>&1; [[ "$DZ_MULTICAST" == "false" ]] )
check "multicast prompt default -> false" "$?" "0"
unset -f ask

echo "== dz_resume: iface up -> verify only (no connect); iface down -> restore =="
: >"$CALLS"
ip() { case "$*" in *"link show doublezero0"*) return 0;; *) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }   # iface UP
state_set dz_client_ip 203.0.113.7; state_set dz_multicast false; state_set solana_home /root/solana
DZ_CLIENT_IP=203.0.113.7 dz_resume >/dev/null 2>&1
check "iface up: no connect ibrl (verify only)" "$(grep -c 'connect ibrl' "$CALLS")" "0"
: >"$CALLS"
ip() { case "$*" in *"link show doublezero0"*) return 1;; *) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }   # iface DOWN
DZ_CLIENT_IP=203.0.113.7 dz_resume >/dev/null 2>&1
check "iface down: restores via connect ibrl" "$(grep -c 'connect ibrl --client-ip 203.0.113.7' "$CALLS")" "1"
check "iface down: re-applies GRE"            "$(grep -c 'ufw allow proto gre' "$CALLS")" "1"
check "resume NEVER regenerates/places a key" "$(grep -c 'solana-keygen new' "$CALLS")" "0"

echo "== doublezerod enabled on boot (so the tunnel auto-restores) =="
: >"$CALLS"
DZ_ENV=mainnet-beta dz_env_override >/dev/null 2>&1
check "doublezerod enabled on boot" "$(grep -c 'systemctl enable doublezerod' "$CALLS")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
