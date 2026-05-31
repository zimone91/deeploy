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
: >"$CALLS"
DZ_CLIENT_IP=203.0.113.7 DZ_MULTICAST=true ASSUME_YES=1 doublezero_run >/dev/null 2>&1
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
DZ_CLIENT_IP=203.0.113.7 DZ_MULTICAST=false ASSUME_YES=1 doublezero_run >/dev/null 2>&1
check "no multicast publish when off" "$(grep -c 'connect multicast' "$CALLS")" "0"

echo "== dz_keypair: fresh setup generates =="
: >"$CALLS"; rm -f "$DZ_KEYPAIR"; : >"$KEYGENLOG"
DZ_CLIENT_IP=203.0.113.7 dz_resolve_config >/dev/null 2>&1
dz_keypair >/dev/null 2>&1
check_true "fresh: dz-keypair generated" "[[ -f \"$DZ_KEYPAIR\" ]]"
check "fresh: keygen invoked once"       "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "1"

echo "== dz_keypair: migration (key present) = default, warns + gates on confirm =="
MOUT=$(ASSUME_YES=1 dz_keypair 2>&1)
check "migration: disconnect shown"     "$(grep -c 'doublezero disconnect' <<<"$MOUT")" "1"
check "migration: stop doublezerod"     "$(grep -c 'systemctl stop doublezerod' <<<"$MOUT")" "1"
check "migration: disable doublezerod"  "$(grep -c 'systemctl disable doublezerod' <<<"$MOUT")" "1"
check "migration: NOT regenerated"      "$(wc -l <"$KEYGENLOG" | tr -d ' ')" "1"
( dz_keypair ) >/dev/null 2>&1   # ASSUME_YES=0, non-interactive -> confirm N -> fail
check "migration decline -> fail"       "$?" "1"

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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
