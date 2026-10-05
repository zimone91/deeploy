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
export DZ_FIND_RETRIES=5 DZ_FIND_INTERVAL=0 DZ_LATENCY_RETRIES=2 DZ_LATENCY_INTERVAL=0 DZ_MCAST_RETRIES=5 DZ_MCAST_INTERVAL=0

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
# find-validator now emits JSON (--json-compact); DZ_FV_JSON overrides per-test.
DZ_FV_JSON='{"cluster":"mainnet-beta","in_leader_schedule":true,"role":"primary","visible_in_gossip":true}'
# A sent request prints its transaction signature (64 bytes, base58). (R10-11)
DZ_TX=ap24ym79C6mLcbSqzKkGfcb33ybxVnqQK74ncx54RgFwF1HkoDZn63o1f18Xvsd6TP9LBtKPnHi8HJYXKEhhArM
doublezero-solana(){ echo "doublezero-solana $*" >>"$CALLS"
    case "$*" in *find-validator*) echo "$DZ_FV_JSON";;
                 *request-validator-access*) echo "Request Solana validator access: $DZ_TX";; esac; }
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
check "phase7: points to ./deeploy.sh dz-connect (runnable cmd, Fix #2)" "$(grep -c './deeploy.sh dz-connect' <<<"$POUT")" "1"
check "phase7: NO bare 'deeploy dz-connect'" "$(grep -cE '(^|[^.[:alnum:]/])deeploy dz-connect' <<<"$POUT")" "0"
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

echo "== N6: the STAKED keypair is REFUSED as a DoubleZero ID (both install paths) =="
# The two install-m600 sites are the ONLY places DeePloy itself copies a key; a
# mixed-up path must never duplicate staked material or register it as a DZ ID.
# The solana-keygen mock keys on the filename: *mainnet-validator-keypair* ->
# the staked pubkey, so a candidate named like the staked key == staked identity.
state_set dz_enabled true
N6_STAKED="$WORK/mainnet-validator-keypair.json"; printf '[9]' >"$N6_STAKED"
state_set staked_keypair "$N6_STAKED"
N6_BAD="$WORK/oops-mainnet-validator-keypair.json"; printf '[9]' >"$N6_BAD"   # == staked pubkey
N6_OK="$WORK/good-dz-id.json"; printf '[1,2,3]' >"$N6_OK"                     # != staked pubkey
# soft path (Phase 5): staked candidate -> FAIL, nothing copied
N6_KP="$WORK/n6-soft-dz.json"; rm -f "$N6_KP"; state_set dz_keypair "$N6_KP"
ask() { REPLY="$N6_BAD"; }
N6SOFT=$( DZ_KEYPAIR="$N6_KP" NONINTERACTIVE=0 STAKED_KEYPAIR="" dz_keypair_check_soft 2>&1 ); N6RC=$?
unset -f ask
check "N6 soft: staked candidate -> fail (rc1)"        "$N6RC" "1"
check_true "N6 soft: nothing copied to the DZ path"    "[[ ! -e \"$N6_KP\" ]]"
check "N6 soft: says REFUSED + names the staked key"   "$(grep -c 'REFUSED.*STAKED' <<<"$N6SOFT")" "1"
# hard path (dz_keypair_migrate): staked candidate -> FAIL before ANY install
rm -f "$WORK/dzconfig/id.json"; : >"$CALLS"
N6HARD=$( DZ_KEYPAIR="$N6_BAD" STAKED_KEYPAIR="" dz_keypair_migrate 2>&1 ); N6HRC=$?
check "N6 migrate: staked candidate -> fail (rc1)"     "$N6HRC" "1"
check "N6 migrate: NO install issued (either dest)"    "$(grep -c 'install -m 600' "$CALLS")" "0"
check_true "N6 migrate: id.json NOT written"           "[[ ! -e \"$WORK/dzconfig/id.json\" ]]"
check "N6 migrate: names the refusal"                  "$(grep -c 'REFUSED' <<<"$N6HARD")" "1"
# non-staked candidate proceeds exactly as before
rm -f "$WORK/dzconfig/id.json"; : >"$CALLS"
( DZ_KEYPAIR="$N6_OK" STAKED_KEYPAIR="" dz_keypair_migrate ) >/dev/null 2>&1
check "N6 migrate: non-staked candidate proceeds"      "$?" "0"
check "N6 migrate: installed to id.json"               "$(grep -c "install -m 600 $N6_OK $WORK/dzconfig/id.json" "$CALLS")" "1"
# staked file ABSENT (pre-swap box) -> proceeds, warns the check was skipped
rm -f "$N6_STAKED" "$WORK/dzconfig/id.json"; : >"$CALLS"
N6ABS=$( DZ_KEYPAIR="$N6_BAD" STAKED_KEYPAIR="" dz_keypair_migrate 2>&1 ); N6ARC=$?
check "N6: staked ABSENT -> proceeds (pre-swap box)"   "$N6ARC" "0"
check "N6: staked ABSENT -> warns check skipped"       "$(grep -c 'identity check skipped' <<<"$N6ABS")" "1"
printf '[9]' >"$N6_STAKED"   # restore for later sections
# staked PRESENT but pubkeys underivable (broken toolchain) -> FAIL-CLOSED:
# refuse the copy rather than skip the check (adversarial-review fix).
mkdir -p "$WORK/nobin"; rm -f "$WORK/dzconfig/id.json"; : >"$CALLS"
N6UND=$( DZ_KEYPAIR="$N6_OK" STAKED_KEYPAIR="" SOLANA_BIN="$WORK/nobin" dz_keypair_migrate 2>&1 ); N6URC=$?
check "N6: underivable pubkeys -> fail-closed (rc1)"   "$N6URC" "1"
check "N6: underivable -> NO install issued"           "$(grep -c 'install -m 600' "$CALLS")" "0"
check "N6: underivable -> names the toolchain"         "$(grep -c 'pubkey derivation failed' <<<"$N6UND")" "1"

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

echo "== F1/R16: leader-schedule gate parses in_leader_schedule JSON (polarity-safe) =="
# Shape-faithful SYNTHETIC fixtures (host000001: throwaway base58 ids + RFC 5737
# TEST-NET IPs — the parser reads only the JSON boolean, never the identity):
# primary=true vs backup=false. The old
# substring 'leader schedul' matched BOTH ("leader scheduled" / "not leader
# scheduled"), and ✅ shows for a backup too. The JSON boolean is the clean anchor;
# fail closed on anything not exactly true.
F1_POS='{"cluster":"mainnet-beta","validator_id":"SynthPrimary1111111111111111111111111111111","gossip_ip":"203.0.113.10","in_leader_schedule":true,"role":"primary","visible_in_gossip":true}'
F1_NEG='{"cluster":"mainnet-beta","validator_id":"SynthBackup22222222222222222222222222222222","gossip_ip":"198.51.100.20","in_leader_schedule":false,"role":"backup","visible_in_gossip":true}'
F1_HUMAN='✅ This validator can only connect as a backup in DoubleZero. It is not leader scheduled and cannot act as a primary validator.'
: >"$CALLS"; DZ_FV_JSON="$F1_POS" _dz_await_in_leader_schedule >/dev/null 2>&1
check "F1: in_leader_schedule:true -> proceeds (rc 0)"        "$?" "0"
check "F1: requests --json-compact"                           "$(grep -c 'find-validator -u mainnet-beta --json-compact' "$CALLS")" "1"
( DZ_FV_JSON="$F1_NEG"; _dz_await_in_leader_schedule ) >/dev/null 2>&1
check "F1: backup (false) -> does NOT proceed (fails)"        "$?" "1"
( DZ_FV_JSON="$F1_HUMAN"; _dz_await_in_leader_schedule ) >/dev/null 2>&1
check "F1: non-JSON output -> fail-closed (does NOT proceed)" "$?" "1"

echo "== F2: connect retries the access-pass race only; fails fast otherwise =="
DZ_PASS_RETRIES=5 DZ_PASS_INTERVAL=0
# Fail with the pass-race error on the first 2 calls, then succeed -> must retry+proceed.
F2N="$WORK/f2n"; : >"$F2N"
_f2_pass_race() { echo c >>"$F2N"; local n; n=$(wc -l <"$F2N" | tr -d ' '); [[ "$n" -lt 3 ]] && { echo "Error: Access Pass not found" >&2; return 1; }; return 0; }
_dz_connect_with_retry _f2_pass_race >/dev/null 2>&1
check "F2: retries past access-pass race -> rc0"         "$?" "0"
check "F2: re-attempted 3x (2 fails + success)"          "$(wc -l <"$F2N" | tr -d ' ')" "3"
# Any OTHER connect error fails fast, NOT retried (don't mask a real failure).
F2B="$WORK/f2b"; : >"$F2B"
_f2_other_err() { echo c >>"$F2B"; echo "Error: tunnel device busy" >&2; return 1; }
( _dz_connect_with_retry _f2_other_err ) >/dev/null 2>&1
check "F2: non-access-pass error fails fast"             "$?" "1"
check "F2: non-access-pass error NOT retried (1 try)"    "$(wc -l <"$F2B" | tr -d ' ')" "1"
# Exhausted access-pass retries -> actionable fail, capped (no infinite loop).
F2E="$WORK/f2e"; : >"$F2E"
_f2_always_race() { echo c >>"$F2E"; echo "Error: Access Pass not found" >&2; return 1; }
( _dz_connect_with_retry _f2_always_race ) >/dev/null 2>&1
check "F2: exhausted retries -> fail (no infinite loop)" "$?" "1"
check "F2: capped at DZ_PASS_RETRIES (5) attempts"       "$(wc -l <"$F2E" | tr -d ' ')" "5"
unset -f _f2_pass_race _f2_other_err _f2_always_race

echo "== dz-connect FULL flow: hard-migrate -> find -> gate -> passport -> connect -> multicast -> displays =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
state_set dz_enabled true
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
printf '[1,2,3]' >"$DZ_KEYPAIR"          # DZ ID placed (hard migrate will install it)
rm -f "$WORK/dzconfig/id.json"
: >"$CALLS"
read() { local v="${!#}"; eval "$v=y"; }  # old-server gate ack
( NONINTERACTIVE=0 dz_connect_run ) >/dev/null 2>&1; RC=$?
unset -f read
check "connect: full flow rc0"               "$RC" "0"
check "connect: hard-migrate installed id.json" "$(grep -c "install -m 600 $DZ_KEYPAIR $WORK/dzconfig/id.json" "$CALLS")" "1"
check "connect: find-validator polled"       "$(grep -c 'passport find-validator -u mainnet-beta' "$CALLS")" "1"
check "connect: passport prepare (staked)"   "$(grep -c 'prepare-validator-access .* --primary-validator-id Stakedid' "$CALLS")" "1"
check "connect: passport request +signature" "$(grep -c 'request-validator-access .* --signature SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567' "$CALLS")" "1"
# X4: the signature is in the EXECUTED argv (above) but must be MASKED in the log.
check "X4: passport request LOGGED with --signature *** (masked)" "$(grep -c -- 'request-validator-access.*--signature \*\*\*' "$LOG_FILE")" "1"
check "X4: real signature NOT written to the log"                 "$(grep -c 'SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567' "$LOG_FILE")" "0"
check "connect: NO --backup-validator-ids (Path 1)" "$(grep -c 'backup-validator-ids' "$CALLS")" "0"
check "connect: connect ibrl issued"          "$(grep -c 'doublezero connect ibrl' "$CALLS")" "1"
check "connect: NO deprecated --client-ip (F6)" "$(grep -c 'connect ibrl --client-ip' "$CALLS")" "0"
check "connect: multicast publish"           "$(grep -c 'connect multicast --publish edge-solana-shreds' "$CALLS")" "1"
check "connect: latency display ran"         "$(grep -c 'doublezero latency' "$CALLS")" "1"
check "connect: status display ran"          "$(grep -c 'doublezero status' "$CALLS")" "1"
check "connect: NO validator restart"        "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "connect: dz_connected recorded"       "$(state_has dz_connected && echo y || echo n)" "y"
check "R10-6 file mode: the derived staked pubkey is recorded" "$(state_get staked_pubkey)" "Stakedid111111111111111111111111111111111"

echo "== dz-connect GATE: --yes ignored, non-interactive aborts before connect ibrl =="
read() { local v="${!#}"; eval "$v=N"; }
GOUT=$( NONINTERACTIVE=0 dz_confirm_old_server_disconnected 2>&1 ); check "gate 'N' -> fail" "$?" "1"
check "gate shows old-server commands" "$(grep -c 'doublezero disconnect' <<<"$GOUT")" "1"
( NONINTERACTIVE=0 ASSUME_YES=1 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate ignores --yes (answered N)" "$?" "1"
unset -f read
NIOUT=$( NONINTERACTIVE=1 dz_confirm_old_server_disconnected 2>&1 ); check "gate non-interactive -> fail" "$?" "1"
check "gate non-interactive: names old-server cmd" "$(grep -q 'doublezero disconnect' <<<"$NIOUT" && echo yes || echo no)" "yes"

echo "== dz-connect GATE: robust to dirty input (Fix #3 — typo-then-correct must not abort) =="
# plain 'y' -> proceed
read() { local v="${!#}"; eval "$v=y"; }
( NONINTERACTIVE=0 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate plain 'y' -> proceed" "$?" "0"
# 'yes' (word) -> proceed
read() { local v="${!#}"; eval "$v=yes"; }
( NONINTERACTIVE=0 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate 'yes' -> proceed" "$?" "0"
# leading/trailing whitespace around y -> proceed (trim)
read() { local v="${!#}"; eval "$v='  y  '"; }
( NONINTERACTIVE=0 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; check "gate '  y  ' (whitespace) -> proceed" "$?" "0"
# SAFETY (adversarial-review finding): a multi-word phrase ending in y/yes must
# NOT auto-proceed past this conflict gate. It re-prompts; here we feed the phrase
# ONCE then EOF (read fails -> "" -> abort), proving it never PROCEEDED.
# gate_blocked <phrase> -> "blocked" if the gate did NOT proceed (rc!=0), else "PROCEEDED".
gate_blocked() {
    # shellcheck disable=SC2034  # GPHRASE is read inside the nested read() via eval
    GPHRASE="$1"; GPN=0
    read() { local v="${!#}"; GPN=$((GPN+1)); if (( GPN == 1 )); then eval "$v=\"\$GPHRASE\""; else return 1; fi; }
    if ( NONINTERACTIVE=0 dz_confirm_old_server_disconnected ) >/dev/null 2>&1; then echo PROCEEDED; else echo blocked; fi
}
check "gate 'maybe y' -> does NOT proceed"     "$(gate_blocked 'maybe y')"     "blocked"
check "gate 'i think yes' -> does NOT proceed" "$(gate_blocked 'i think yes')" "blocked"
check "gate 'no way' -> does NOT proceed"      "$(gate_blocked 'no way')"      "blocked"
unset -f read gate_blocked
# a typo that is NEITHER y nor n must RE-PROMPT, not abort. Feed: garbage, then y.
GATE_TRIES="$WORK/gatetries"; : >"$GATE_TRIES"
read() { local v="${!#}"; echo t >>"$GATE_TRIES"; if [[ "$(wc -l <"$GATE_TRIES")" -lt 2 ]]; then eval "$v=zzz"; else eval "$v=y"; fi; }
TYPO=$( NONINTERACTIVE=0 dz_confirm_old_server_disconnected 2>&1 ); check "gate typo-then-'y' -> proceed (re-prompted)" "$?" "0"
check "gate re-prompted on typo (2 reads)" "$(wc -l <"$GATE_TRIES" | tr -d ' ')" "2"
check "gate typo -> 'Please answer y or n'" "$(grep -c 'Please answer y or n' <<<"$TYPO")" "1"
unset -f read

echo "== display parsers: latency nearest device + status two-tunnel verdict (synthetic fixture, real shape) =="
LAT=$(printf '%s\n' \
  ' Pubkey | Code        | IP        | Min  | Max  | Avg    | reachable ' \
  ' pk1    | dz-syn2-sw01 | 1.2.3.4  | 9.1  | 9.9  | 9.40 ms| true ' \
  ' pk2    | dz-syn1-sw01 | 5.6.7.8  | 0.2  | 0.3  | 0.24 ms| true ')
check "latency: nearest = lowest Avg (syn1 0.24)" "$(printf '%s\n' "$LAT" | _dz_parse_latency_nearest)" "dz-syn1-sw01 0.24"

echo "== latency TOP-N (Fix #4 — show only the nearest few, not the ~150-row dump) =="
# Build a 10-device table; top-N must return the N lowest-Avg, sorted ascending.
LATBIG=' Pubkey | Code | IP | Min | Max | Avg | reachable'
for i in 1 2 3 4 5 6 7 8 9 10; do LATBIG+=$'\n'" pk$i | dz-dev$i | 1.1.1.$i | 0 | 0 | $i.00 ms | true"; done
TOP3=$(printf '%s\n' "$LATBIG" | _dz_parse_latency_topn 3)
check "top-N: returns exactly N rows"        "$(printf '%s\n' "$TOP3" | grep -c 'dz-dev')" "3"
check "top-N: nearest first (dev1 1.00)"     "$(printf '%s\n' "$TOP3" | head -1 | grep -c 'dz-dev1 ')" "1"
check "top-N: 3rd is dev3 (ascending)"       "$(printf '%s\n' "$TOP3" | sed -n 3p | grep -c 'dz-dev3 ')" "1"
check "top-N: does NOT include the far dev10" "$(printf '%s\n' "$TOP3" | grep -c 'dz-dev10')" "0"
check "top-N caps at available rows (ask 99 of 10)" "$(printf '%s\n' "$LATBIG" | _dz_parse_latency_topn 99 | grep -c 'dz-dev')" "10"
# adversarial-review finding #1: a NON-NUMERIC N must NOT dump the whole table
# (awk lexicographic-compare gotcha). Falls back to the default (8), not all 10.
check "top-N: non-numeric N -> default 8 (NOT whole table)" "$(printf '%s\n' "$LATBIG" | _dz_parse_latency_topn abc | grep -c 'dz-dev')" "8"
check "top-N: empty N -> default 8"          "$(printf '%s\n' "$LATBIG" | _dz_parse_latency_topn '' | grep -c 'dz-dev')" "8"
# adversarial-review finding #2: a pathological all-dot Avg ('...') must be
# REJECTED (else avg+0=0 sorts it to the top as a bogus 0ms 'nearest').
LATDOT=$(printf '%s\n' ' Code | Avg | reachable' ' dz-bogus | ... ms | true' ' dz-real | 3.5 ms | true')
check "latency: all-dot Avg rejected, real row chosen" "$(printf '%s\n' "$LATDOT" | _dz_parse_latency_nearest)" "dz-real 3.5"
check "top-N: all-dot Avg row excluded"      "$(printf '%s\n' "$LATDOT" | _dz_parse_latency_topn 5 | grep -c 'dz-bogus')" "0"
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

echo "== dz_show_status POLLS until BOTH tunnels up (multicast lags — the real-box case) =="
# IBRL up immediately; multicast 'Pending BGP Session' for the first 2 polls, then up.
SPOLL="$WORK/spoll"; : >"$SPOLL"
doublezero() { case "$*" in status)
    echo s >>"$SPOLL"; local mc='Pending BGP Session'; [[ "$(wc -l <"$SPOLL")" -ge 3 ]] && mc='BGP Session Up'
    printf '%s\n' \
      ' Tunnel Status | Tunnel Name | Current Device | Metro | Multicast Groups' \
      ' BGP Session Up | doublezero0 | dz-syn1-sw01 | metro-a |' \
      " ${mc} | doublezero1 | dz-syn1-sw01 | metro-a | P:edge-solana-shreds";;
  *) echo "doublezero $*" >>"$CALLS";; esac; }
SOUT=$( DZ_MCAST_RETRIES=5 DZ_MCAST_INTERVAL=0 dz_show_status 2>&1 ); SRC=$?
check "status-poll: rc0"                       "$SRC" "0"
check "status-poll: polled until mcast up (3x)" "$(wc -l <"$SPOLL" | tr -d ' ')" "3"
check "status-poll: success verdict reached"   "$(grep -c 'publishing shreds to edge-solana-shreds' <<<"$SOUT")" "1"
# multicast NEVER comes up -> warn (IBRL up, multicast still pending after timeout)
: >"$SPOLL"
doublezero() { case "$*" in status)
    echo s >>"$SPOLL"
    printf '%s\n' \
      ' Tunnel Status | Tunnel Name | Current Device | Metro | Multicast Groups' \
      ' BGP Session Up | doublezero0 | dz-syn1-sw01 | metro-a |' \
      ' Pending BGP Session | doublezero1 | dz-syn1-sw01 | metro-a | P:edge-solana-shreds';;
  *) :;; esac; }
WOUT=$( DZ_MCAST_RETRIES=3 DZ_MCAST_INTERVAL=0 dz_show_status 2>&1 )
check "status-poll: mcast-stuck -> warns IBRL up but multicast pending" "$(grep -c 'Multicast BGP session is still' <<<"$WOUT")" "1"
check "R10-11: multicast stuck -> the multicast command, not dz-connect" "$(grep -cF "run 'doublezero connect multicast --publish edge-solana-shreds' — not dz-connect" <<<"$WOUT")|$(grep -c "re-run '.*dz-connect'" <<<"$WOUT")" "1|0"
check "status-poll: mcast-stuck polled the full timeout (3x)" "$(wc -l <"$SPOLL" | tr -d ' ')" "3"
# restore the simple status mock for any later use
doublezero() { echo "doublezero $*" >>"$CALLS"; case "$*" in address) echo "DZid11111111111111111111111111111111111111";;
                 latency) printf '%s\n' ' Code | Avg | reachable ' ' dz-syn1-sw01 | 0.24 ms | true ';;
                 status)  printf '%s\n' ' Tunnel Status | Tunnel Name | Current Device | Metro | Multicast Groups ' ' BGP Session Up | doublezero0 | dz-syn1-sw01 | metro-a | ' ' BGP Session Up | doublezero1 | dz-syn1-sw01 | metro-a | P:edge-solana-shreds ';; esac; }

echo "== N16: DZ_ENV enum-gated before rendering the doublezerod override =="
( DZ_ENV='mainnet-beta; rm -rf /' dz_env_override ) >/dev/null 2>&1
check "N16: hostile DZ_ENV -> dz_env_override fails" "$?" "1"
check_true "N16: hostile value NOT rendered into the unit" "! grep -q 'rm -rf' \"$DZ_OVERRIDE_CONF\" 2>/dev/null"
( DZ_ENV=bogus dz_env_override ) >/dev/null 2>&1
check "N16: unknown env word -> fails (enum, not charset)" "$?" "1"
( DZ_ENV=testnet dz_env_override ) >/dev/null 2>&1
check "N16: testnet accepted"                        "$?" "0"
( DZ_ENV=mainnet-beta dz_env_override ) >/dev/null 2>&1
check "N16: shipped default mainnet-beta accepted"   "$?" "0"
# Assert on the MESSAGE, not just rc — dz_connect_run fails later for other
# reasons in this harness, so a bare rc check couldn't pin THIS gate
# (adversarial-review fix: the assertion was mutation-insensitive).
N16CONN=$( DZ_ENV=bogus dz_connect_run 2>&1 ); N16CRC=$?
check "N16: dz-connect entry validates DZ_ENV too (rc1)" "$N16CRC" "1"
check "N16: dz-connect names the DZ_ENV rejection"       "$(grep -c "DZ_ENV 'bogus' invalid" <<<"$N16CONN")" "1"

echo "== dz_resume: gated on dz_connected (NOT dz_enabled); no-op until connected =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home /root/solana; state_set dz_enabled true   # enabled but NOT connected
: >"$CALLS"
RES=$(dz_resume 2>&1); check "resume no-op when not connected -> rc0" "$?" "0"
check "resume no-op: nothing connected"        "$(grep -c 'connect ibrl' "$CALLS")" "0"
check "resume no-op: says nothing to restore"  "$(grep -c 'nothing to restore' <<<"$RES")" "1"
# connected + iface up -> verify only
state_set dz_connected t
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 0;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+up: no reconnect"      "$(grep -c 'connect ibrl' "$CALLS")" "0"
# connected + iface down -> restore
: >"$CALLS"; ip() { case "$*" in *"link show"*) return 1;; *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; esac; }
dz_resume >/dev/null 2>&1
check "resume connected+down: reconnects"      "$(grep -c 'connect ibrl' "$CALLS")" "1"
check "resume NEVER re-places a key"           "$(grep -c 'install -m 600' "$CALLS")" "0"

echo "== R10-6: offbox dz-connect — no staked file; signature from outside; the sync identity pays, dry-run first =="
ip() { case "$*" in *"route get"*) echo "1.1.1.1 dev eth0 src 203.0.113.7";; *"link show"*) return 0;; *) echo x;; esac; }
OFF_STAKED=kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu
OFF_SIG=4XR92Zct9ZodXzisJ4kov3upmTvMotYVrg65MHP8aoCjSPJwUa7vjaXK5VhDF7ZiiF16v7cY5BPazCLnVqZ3yzb
check "fixtures: staked pubkey 32 bytes, signature 64" "$(b58_len "$OFF_STAKED")|$(b58_len "$OFF_SIG")" "32|64"
# Logging stubs: every solana / solana-keygen argv lands in $KEYGENLOG, so a read
# of the staked keypair would show up there.
export STUB_EVIL_PK="$OFF_STAKED"
cat >"$WORK/bin/solana-keygen" <<'EOF'
#!/bin/bash
echo "solana-keygen $*" >>"$KEYGENLOG"
case "$1" in
  pubkey) case "$2" in *mainnet-validator-keypair*) echo "Stakedid111111111111111111111111111111111";;
                       *unstaked-identity*) echo "SyncPayer11111111111111111111111111111111111";;
                       *evil-dz*) echo "$STUB_EVIL_PK";;
                       *) echo "Other11111111111111111111111111111111111111";; esac ;;
esac
EOF
cat >"$WORK/bin/solana" <<'EOF'
#!/bin/bash
echo "solana $*" >>"$KEYGENLOG"
case "$1" in sign-offchain-message) echo "SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567";;
             balance) echo "0.5 SOL";; esac
EOF
chmod +x "$WORK/bin/solana-keygen" "$WORK/bin/solana"
DZ_DRY=ok; DZ_REQ=sent
doublezero-solana() { echo "doublezero-solana $*" >>"$CALLS"
    case "$*" in
        *find-validator*)    echo '{"cluster":"mainnet-beta","in_leader_schedule":true,"role":"primary","visible_in_gossip":true}' ;;
        *"fetch --config"*)  echo '{"program_config":"PCfg","is_paused":false,"is_request_access_paused":false,"request_deposit_sol":1.5,"request_fee_sol":0.00025}' ;;
        *request-validator-access*--dry-run*)
            case "$DZ_DRY" in
                ok)     printf 'Compute units consumed: 9876\nSimulated program logs:\n  Program dzPass invoke [1]\n  Program dzPass success\n' ;;
                short)  printf 'Simulated program logs:\n  Program 11111111111111111111111111111111 invoke [2]\n  Transfer: insufficient lamports 1000, need 1501000\n'
                        echo "Error: Simulation failed" >&2; return 1 ;;
                errors) printf '\nErrors found:\n - Validator is not in gossip\n'; return 0 ;;
                badsig) echo "Error: Signature verification failed" >&2; return 1 ;;
                nosim)  echo "Request Solana validator access: 5TxSig" ;;          # rc 0, simulated nothing
                both)   printf 'Errors found:\n - x\nSimulated program logs:\n  Program dzPass success\n' ;;
                pending) echo "Error: Access request already exists: ReqPda1111111111111111111111111111111111111" >&2; return 1 ;;
                sentanyway) echo "Request Solana validator access: $DZ_TX" ;;   # the CLI sent instead of simulating
            esac ;;
        *request-validator-access*)
            case "$DZ_REQ" in
                sent)    echo "Request Solana validator access: $DZ_TX" ;;
                errors)  printf '\nErrors found:\n - Validator is not in gossip\n'; return 0 ;;
                pending) echo "Error: Access request already exists: ReqPda1111111111111111111111111111111111111" >&2; return 1 ;;
                failed)  echo "Error: RPC request timed out" >&2; return 1 ;;
                garbled) echo "Request Solana validator access: 5TxSig" ;;
                sentrc1) echo "Request Solana validator access: $DZ_TX"; echo "Error: verbose output failed" >&2; return 1 ;;
            esac ;;
    esac; }
off_state() {
    rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
    state_set solana_home /root/solana; state_set dz_enabled true
    state_set staked_key_mode offbox; state_set staked_pubkey "$OFF_STAKED"; state_set sync_identity "$SYNC_KP"
    printf '[1,2,3]' >"$DZ_KEYPAIR"; rm -f "$WORK/dzconfig/id.json"
    : >"$CALLS"; : >"$KEYGENLOG"; : >"$LOG_FILE"
}
SYNC_KP="$WORK/unstaked-identity.json"; printf '[1]' >"$SYNC_KP"
rm -f "$WORK/mainnet-validator-keypair.json"                # no staked file anywhere

off_state
read() { local v="${!#}"; eval "$v=y"; }                    # old-server gate ack
OFFOUT=$( NONINTERACTIVE=0 DZ_SIGNATURE="$OFF_SIG" dz_connect_run 2>&1 ); RC=$?
unset -f read
check "offbox: full flow with no staked file -> rc0"   "$RC" "0"
check "offbox: prepare names the staked pubkey (state)" "$(grep -c "prepare-validator-access .* --primary-validator-id $OFF_STAKED" "$CALLS")" "1"
check "offbox: the first request is the dry-run, -k sync" "$(grep 'request-validator-access' "$CALLS" | head -1 | grep -c -- "--signature $OFF_SIG -u mainnet-beta -k $SYNC_KP --dry-run\$")" "1"
check "offbox: then the request, -k sync, same signature" "$(grep 'request-validator-access' "$CALLS" | sed -n 2p | grep -c -- "--signature $OFF_SIG -u mainnet-beta -k $SYNC_KP\$")" "1"
check "offbox: two request calls in all"               "$(grep -c 'request-validator-access' "$CALLS")" "2"
check "offbox: nothing signed on this box"             "$(grep -c 'sign-offchain-message' "$KEYGENLOG")" "0"
check "offbox: payer and balance shown"                "$(grep -c 'The sync identity pays for the request: SyncPayer11111111111111111111111111111111111 (balance: 0.5 SOL)' <<<"$OFFOUT")" "1"
check "offbox: deposit from the program config shown" "$(grep -c "request deposit (1.5 SOL)" <<<"$OFFOUT")" "1"
check "offbox: a grant refunds the sync identity"      "$(grep -c 'come back to the sync identity' <<<"$OFFOUT")" "1"
check "X4 offbox: both calls logged with --signature ***" "$(grep -c -- 'request-validator-access.*--signature \*\*\*' "$LOG_FILE")" "2"
check "X4 offbox: the signature never reaches the log" "$(grep -c "$OFF_SIG" "$LOG_FILE")" "0"
check "offbox: dz_connected recorded"                  "$(state_has dz_connected && echo y || echo n)" "y"

# Read trap: a keypair fixture at the default staked path, and a stale staked
# path in state (an old conf). offbox must never open or name it.
off_state
printf '[9]' >"$WORK/mainnet-validator-keypair.json"; state_set staked_keypair "$WORK/mainnet-validator-keypair.json"
read() { local v="${!#}"; eval "$v=y"; }
( NONINTERACTIVE=0 DZ_SIGNATURE="$OFF_SIG" dz_connect_run ) >/dev/null 2>&1; RC=$?
unset -f read
check "offbox read trap: flow rc0"                     "$RC" "0"
check "offbox read trap: no solana/keygen call names the staked file" "$(grep -c 'mainnet-validator-keypair' "$KEYGENLOG")" "0"
check "offbox read trap: no DZ CLI call names it"      "$(grep -c 'mainnet-validator-keypair' "$CALLS")" "0"
rm -f "$WORK/mainnet-validator-keypair.json"

echo "== R10-6: offbox passport — every way it must stop before anything is sent =="
offpass() { NONINTERACTIVE=1 STAKED_KEY_MODE=offbox SYNC_IDENTITY="$SYNC_KP" dz_passport DZid1111 "$OFF_STAKED" 2>&1; }
off_state; DZ_DRY=badsig
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "wrong signature: the dry-run fails -> fail"     "$RC" "1"
check "wrong signature: the CLI's reason is shown"     "$(grep -c 'Signature verification failed' <<<"$OUT")" "1"
check "wrong signature: nothing sent, exact sign cmd"  "$(grep -c 'nothing was sent' <<<"$OUT")|$(grep -cF 'sign exactly  solana sign-offchain-message "service_key=DZid1111" -k <staked.json>' <<<"$OUT")" "1|1"
check "wrong signature: only the dry-run ran"          "$(grep -c 'request-validator-access' "$CALLS")|$(grep -c -- '--dry-run' "$CALLS")" "1|1"
off_state; DZ_DRY=short
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "short balance: fail with the shortfall"         "$RC|$(grep -c 'short by 1500000 lamports: it has 1000, the request needs 1501000' <<<"$OUT")" "1|1"
check "short balance: only the dry-run ran"            "$(grep -c 'request-validator-access' "$CALLS")" "1"
off_state; DZ_DRY=errors
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "'Errors found:' with exit 0: still a fail"      "$RC|$(grep -c 'Validator is not in gossip' <<<"$OUT")" "1|1"
check "'Errors found:': only the dry-run ran"          "$(grep -c 'request-validator-access' "$CALLS")" "1"
off_state; DZ_DRY=nosim
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "dry-run printed no simulation (rc 0): fail"   "$RC|$(grep -c 'request-validator-access' "$CALLS")" "1|1"
off_state; DZ_DRY=both
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "simulation printed AND 'Errors found:' (rc 0): fail" "$RC|$(grep -c 'request-validator-access' "$CALLS")" "1|1"
off_state; DZ_DRY=ok
OUT=$( unset DZ_SIGNATURE; offpass ); RC=$?
check "no signature, non-interactive -> fail"          "$RC" "1"
check "no signature: prints the exact command and the flag" "$(grep -cF 'run exactly:  solana sign-offchain-message "service_key=DZid1111" -k <staked.json>' <<<"$OUT")|$(grep -c 'dz-connect --dz-signature' <<<"$OUT")" "1|1"
check "no signature: no request call"                  "$(grep -c 'request-validator-access' "$CALLS")" "0"
off_state
OUT=$( DZ_SIGNATURE="SigVa1idBase58Test2ZqWeRtYuPaSdFgHjKxCvBnM34567" offpass ); RC=$?
check "not a 64-byte signature -> fail before any request" "$RC|$(grep -c 'not a 64-byte base58 signature' <<<"$OUT")|$(grep -c 'request-validator-access' "$CALLS")" "1|1|0"
off_state
ask() { REPLY="$OFF_SIG"; }                                 # the operator pastes it (common.sh's ask is unset above)
OUT=$( unset DZ_SIGNATURE; NONINTERACTIVE=0 STAKED_KEY_MODE=offbox SYNC_IDENTITY="$SYNC_KP" dz_passport DZid1111 "$OFF_STAKED" 2>&1 ); RC=$?
unset -f ask
check "interactive: shows the command, takes the pasted signature" "$RC|$(grep -c 'Where the staked key lives, run exactly:' <<<"$OUT")|$(grep -c 'request-validator-access' "$CALLS")" "0|1|2"

echo "== R10-6: offbox guards — the DZ-ID check compares pubkeys; the gate needs pubkey + payer =="
off_state
EVIL="$WORK/evil-dz.json"; printf '[7]' >"$EVIL"
OUT=$( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$OFF_STAKED" _dz_assert_not_staked_key "$EVIL" 2>&1 ); RC=$?
check "offbox: a DZ ID with the staked pubkey -> REFUSED" "$RC|$(grep -c 'REFUSED' <<<"$OUT")" "1|1"
( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$OFF_STAKED" _dz_assert_not_staked_key "$DZ_KEYPAIR" ) >/dev/null 2>&1
check "offbox: a different DZ ID -> passes"            "$?" "0"
state_clear staked_pubkey
OUT=$( STAKED_KEY_MODE=offbox STAKED_PUBKEY="" _dz_assert_not_staked_key "$DZ_KEYPAIR" 2>&1 ); RC=$?
check "offbox: no staked pubkey -> fail-closed"        "$RC|$(grep -c 'no staked pubkey is recorded' <<<"$OUT")" "1|1"
check "offbox DZ-ID check: the staked file never named" "$(grep -c 'mainnet-validator-keypair' "$KEYGENLOG")" "0"
off_state; state_clear staked_pubkey
OUT=$( dz_connect_run 2>&1 ); RC=$?
check "offbox gate: no staked pubkey -> fail"          "$RC|$(grep -cF 'set STAKED_PUBKEY (or re-run phase 5)' <<<"$OUT")" "1|1"
( off_state; state_set staked_keypair "$WORK/stale/mainnet-validator-keypair.json"
  STAKED_KEYPAIR=/env/mainnet-validator-keypair.json; dz_resolve_config
  printf '%s|%s' "${STAKED_KEYPAIR:-<empty>}" "$STAKED_KEY_MODE" ) >"$WORK/dzrc" 2>/dev/null
check "offbox dz_resolve_config: a stale staked path is not resolved" "$(cat "$WORK/dzrc")" "<empty>|offbox"
off_state; state_set sync_identity "$WORK/no-such-sync.json"
OUT=$( dz_connect_run 2>&1 ); RC=$?
check "offbox gate: the paying sync identity missing -> fail" "$RC|$(grep -c 'pays for the passport request, but it is not on this box' <<<"$OUT")" "1|1"

echo "== R10-11: the passport outcome comes from the CLI's output, not its exit code =="
file_state() {
    rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
    state_set solana_home /root/solana; state_set dz_enabled true; state_set staked_key_mode file
    state_set staked_keypair "$WORK/mainnet-validator-keypair.json"; printf '[9]' >"$WORK/mainnet-validator-keypair.json"
    : >"$CALLS"; : >"$KEYGENLOG"
}
filepass() { NONINTERACTIVE=1 STAKED_KEY_MODE=file STAKED_KEYPAIR="$WORK/mainnet-validator-keypair.json" \
             dz_passport DZid1111 Stakedid111111111111111111111111111111111 2>&1; }
file_state; DZ_REQ=sent
OUT=$(filepass); RC=$?
check "R10-11 sent (64-byte tx printed): requested"     "$RC|$(grep -c 'Passport access requested' <<<"$OUT")" "0|1"
file_state; DZ_REQ=errors
OUT=$(filepass); RC=$?
check "R10-11 'Errors found:' with exit 0: fail, NOT 'requested'" "$RC|$(grep -c 'Passport access requested' <<<"$OUT")|$(grep -c 'was NOT sent' <<<"$OUT")" "1|0|1"
check "R10-11 'Errors found:': the CLI's errors are shown" "$(grep -c 'Validator is not in gossip' <<<"$OUT")" "1"
file_state; DZ_REQ=pending
OUT=$(filepass); RC=$?
check "R10-11 already pending: not sent again, goes on" "$RC|$(grep -c 'already pending — not sent again' <<<"$OUT")|$(grep -c 'Passport access requested' <<<"$OUT")" "0|1|0"
file_state; DZ_REQ=failed
OUT=$(filepass); RC=$?
check "R10-11 CLI error: fail, not 'requested', names the check" "$RC|$(grep -c 'Passport access requested' <<<"$OUT")|$(grep -c 'passport fetch --access-request DZid1111 -u mainnet-beta' <<<"$OUT")" "1|0|1"
file_state; DZ_REQ=garbled
OUT=$(filepass); RC=$?
check "R10-11 success line without a 64-byte tx: not confirmed" "$RC|$(grep -c 'Passport access requested' <<<"$OUT")" "1|0"
file_state; DZ_REQ=sentrc1
OUT=$(filepass); RC=$?
check "R10-11 tx printed but exit 1: not claimed, check named" "$RC|$(grep -c 'Passport access requested' <<<"$OUT")|$(grep -c 'not confirmed' <<<"$OUT")" "1|0|1"
file_state; DZ_REQ=pending
printf '[1,2,3]' >"$DZ_KEYPAIR"; rm -f "$WORK/dzconfig/id.json"
read() { local v="${!#}"; eval "$v=y"; }
( NONINTERACTIVE=0 dz_connect_run ) >/dev/null 2>&1; RC=$?
unset -f read
check "R10-11 pending, whole dz-connect: goes on to connect" "$RC|$(grep -c 'doublezero connect ibrl' "$CALLS")" "0|1"
DZ_REQ=sent
off_state; DZ_DRY=pending
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "R10-11 offbox: dry-run says pending -> nothing sent, goes on" "$RC|$(grep -c 'request-validator-access' "$CALLS")|$(grep -c 'already pending' <<<"$OUT")" "0|1|1"
off_state; DZ_DRY=sentanyway
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "R10-11 offbox: a dry-run that sent -> never sent twice" "$RC|$(grep -c 'request-validator-access' "$CALLS")|$(grep -c 'not sending another' <<<"$OUT")" "0|1|1"
off_state; DZ_DRY=ok; DZ_REQ=errors
OUT=$( DZ_SIGNATURE="$OFF_SIG" offpass ); RC=$?
check "R10-11 offbox: the real request's 'Errors found:' -> fail" "$RC|$(grep -c 'Passport access requested' <<<"$OUT")" "1|0"
DZ_DRY=ok; DZ_REQ=sent
# What the run did is kept for an exhausted connect's message. Each call runs in
# a subshell that prints the variable afterwards; a fail() there prints nothing.
outcome_after() { local mode=$1; shift
    ( DZ_PASSPORT_OUTCOME=""
      if [[ "$mode" == file ]]; then file_state; filepass >/dev/null 2>&1
      else off_state; DZ_SIGNATURE="$OFF_SIG" offpass >/dev/null 2>&1; fi
      printf '%s' "$DZ_PASSPORT_OUTCOME" ); }
check "R10-11 sent: recorded for the connect message"    "$(DZ_REQ=sent outcome_after file)"          "sent"
check "R10-11 pending: recorded for the connect message" "$(DZ_REQ=pending outcome_after file)"       "pending"
check "R10-11 offbox dry-run pending: recorded"          "$(DZ_DRY=pending outcome_after offbox)"     "pending"
check "R10-11 offbox dry-run that sent: recorded"        "$(DZ_DRY=sentanyway outcome_after offbox)"  "sent"
DZ_DRY=ok; DZ_REQ=sent

echo "== R10-11: an exhausted connect says what this run sent, and when a re-run costs =="
_r11_race() { echo "Error: Access Pass not found" >&2; return 1; }
state_set dz_id DZid1111
for o in sent pending none; do
    OUT=$( DZ_PASSPORT_OUTCOME="${o/none/}" DZ_PASS_RETRIES=2 DZ_PASS_INTERVAL=0 _dz_connect_with_retry _r11_race 2>&1 ); RC=$?
    case "$o" in
        sent)    want='The access request was sent in this run.' ;;
        pending) want='An access request for this DoubleZero ID was already pending.' ;;
        none)    want='No access request was sent in this run.' ;;
    esac
    check "R10-11 exhausted ($o): fail, says what happened" "$RC|$(grep -cF "$want" <<<"$OUT")" "1|1"
    check "R10-11 exhausted ($o): no 'WAS submitted' / 'idempotent'" "$(grep -c -e 'WAS submitted' -e 'idempotent' <<<"$OUT")" "0"
done
check "R10-11 exhausted: names the check, the costly re-run, the deposit" "$(grep -cF 'passport fetch --access-request DZid1111 -u mainnet-beta' <<<"$OUT")|$(grep -c 'would send, and pay for, a new request, and a deny keeps the deposit' <<<"$OUT")|$(grep -cF "retry only '_r11_race'" <<<"$OUT")" "1|1|1"
unset -f _r11_race

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
