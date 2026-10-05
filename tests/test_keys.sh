#!/usr/bin/env bash
# Self-contained tests for lib/keys.sh — no solana toolchain. The keygen/pubkey/
# solana wrappers are mocked. Focus: real key NEVER generated, idempotent
# no-regen, and the staked==unstaked / vote==identity foolproofing.
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
# shellcheck source-path=SCRIPTDIR source=../lib/keys.sh
source "$ROOT/lib/keys.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }
check_ge()    { if (( $2 >= $3 )); then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s (%s < %s)\n' "$1" "$2" "$3"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; KEYGEN="$WORK/keygen"; : >"$CALLS"; : >"$KEYGEN"

mkpub() { local s=$1; while [[ ${#s} -lt 43 ]]; do s="${s}1"; done; printf '%s' "${s:0:43}"; }
VOTE=$(mkpub Vote)

# Mocked wrappers. One throwaway now: the unstaked sync identity.
SYNC_PUB=$(mkpub Sync); STAKED_PUB=$(mkpub Staked)
_keys_keygen_new() { echo "keygen $1" >>"$KEYGEN"; printf '[1,2,3]' >"$1"; }
_keys_pubkey() { case "$1" in
    *unstaked*)                  printf '%s' "$SYNC_PUB" ;;
    *mainnet-validator-keypair*) printf '%s' "$STAKED_PUB" ;;
    *)                           printf '%s' "$(mkpub Other)" ;; esac; }
_keys_solana() { echo "solana $*" >>"$CALLS"; }

echo "== _keys_valid_pubkey =="
check_true  "valid 43-char base58" "_keys_valid_pubkey $(mkpub Abc)"
check_false "too short"            "_keys_valid_pubkey abc"
check_false "contains 0"           "_keys_valid_pubkey 0$(mkpub Abc)"

echo "== resolve_config: single sync identity + vote validation =="
state_set solana_home "$WORK/home"
unset SYNC_IDENTITY UNSTAKED_KEYPAIR STAKED_KEYPAIR
VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
check "sync_identity path (= unstaked file)" "$SYNC_IDENTITY"  "$WORK/home/unstaked-identity.json"
check "staked path"   "$STAKED_KEYPAIR"   "$WORK/home/mainnet-validator-keypair.json"
check "sync_identity recorded to state"    "$(state_get sync_identity)" "$WORK/home/unstaked-identity.json"
check "no fake_identity state (mvkfake gone)" "$(state_get fake_identity '<unset>')" "<unset>"
check "vote recorded" "$(state_get vote_account_pubkey)" "$VOTE"
# UNSTAKED_KEYPAIR (conf key) feeds SYNC_IDENTITY when set.
unset SYNC_IDENTITY
UNSTAKED_KEYPAIR="$WORK/home/custom-unstaked.json" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
check "UNSTAKED_KEYPAIR conf-key -> sync_identity" "$SYNC_IDENTITY" "$WORK/home/custom-unstaked.json"
unset UNSTAKED_KEYPAIR
( VOTE_ACCOUNT_PUBKEY="bad!key" keys_resolve_config ) >/dev/null 2>&1
check "invalid vote -> fail" "$?" "1"

echo "== generate: ONE key (unstaked sync identity), real key NEVER generated, idempotent =="
: >"$KEYGEN"; rm -rf "${WORK:?}/home"
SYNC_IDENTITY="$WORK/home/unstaked-identity.json" keys_generate >/dev/null 2>&1
check "exactly 1 keygen (single identity)" "$(wc -l <"$KEYGEN" | tr -d ' ')" "1"
check "unstaked keygen issued"  "$(grep -c 'unstaked' "$KEYGEN")"  "1"
check "no mvkfake keygen"       "$(grep -c 'mvkfake' "$KEYGEN")"   "0"
check_true "sync-identity file created" "[[ -f \"$WORK/home/unstaked-identity.json\" ]]"
check_false "no mvkfake dir created"    "[[ -d \"$WORK/home/mvkfake\" ]]"
check_false "real key NOT created" "[[ -f \"$WORK/home/mainnet-validator-keypair.json\" ]]"
: >"$KEYGEN"
SYNC_IDENTITY="$WORK/home/unstaked-identity.json" keys_generate >/dev/null 2>&1
check "idempotent: no regen when present" "$(wc -l <"$KEYGEN" | tr -d ' ')" "0"

echo "== validate: foolproofing (vote != identity, staked != sync) =="
SYNC_PUB=$(mkpub Vote)                                # identity == vote
( SYNC_IDENTITY=/x/unstaked.json STAKED_KEYPAIR=/x/none \
  VOTE_ACCOUNT_PUBKEY="$(mkpub Vote)" keys_validate ) >/dev/null 2>&1
check "vote==identity -> FAIL" "$?" "1"
SYNC_PUB=$(mkpub Sync); STAKED_PUB=$(mkpub Sync)      # staked == sync identity
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
( SYNC_IDENTITY=/x/unstaked.json \
  STAKED_KEYPAIR="$WORK/mainnet-validator-keypair.json" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate ) >/dev/null 2>&1
check "real-key==sync -> FAIL" "$?" "1"
SYNC_PUB=$(mkpub Sync); STAKED_PUB=$(mkpub Staked)    # distinct
SYNC_IDENTITY=/x/unstaked.json STAKED_KEYPAIR=/x/none \
  VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate >/dev/null 2>&1
check "vote!=identity, staked!=sync -> passes" "$?" "0"

echo "== config: ONE combined config set (prints once), Fix 3 =="
: >"$CALLS"
STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json keys_config_cli >/dev/null 2>&1
check "exactly one 'config set' call"  "$(grep -c 'solana config set' "$CALLS")" "1"
check "combined call has --url"        "$(grep -c 'config set --url https://api.mainnet-beta.solana.com .*--keypair' "$CALLS")" "1"
check "combined call has real keypair" "$(grep -c -- '--keypair /root/solana/mainnet-validator-keypair.json' "$CALLS")" "1"
MAN=$(STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json LEDGER_PATH=/root/solana/ledger keys_print_manual 2>&1)
check_ge "manual shows real-key path"        "$(grep -c '/root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "set-identity --require-tower path-form" "$(grep -c 'set-identity --require-tower /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "authorized-voter add path-form"    "$(grep -c 'authorized-voter add /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "NO stdin redirect form (dropped)"  "$(grep -c 'set-identity < ' <<<"$MAN")" "0"
check_ge "never-touch wording"               "$(grep -ci 'never' <<<"$MAN")" "1"
# R10-9: hot swap = the old validator stops, its tower moves here, then
# --require-tower; the cold line carries its condition.
check    "old validator stops voting first"  "$(grep -c 'OLD validator first' <<<"$MAN")" "1"
check    "a restart of the old one comes back unstaked" "$(grep -c 'Make sure a restart of the OLD validator comes back unstaked' <<<"$MAN")" "1"
check    "tower copied to this ledger"       "$(grep -c 'tower-1_9-<staked-pubkey>.bin <this-box>:/root/solana/ledger/' <<<"$MAN")" "1"
check    "cold bring-up states its condition" "$(grep -c "finalized slot is at least 300 slots past the vote account's lastVote" <<<"$MAN")" "1"
check    "no bare 'No tower transfer needed'" "$(grep -c 'No tower transfer needed' <<<"$MAN")" "0"
# R10-6 (KEYMODEL-DZ-READS): in dz-connect the key signs twice, not "one message".
check    "file mode names both dz-connect signatures" "$(grep -c 'signs the passport message and the request transaction it pays for' <<<"$MAN")" "1"
check    "no 'sign one DoubleZero passport message'"  "$(grep -c 'sign one DoubleZero passport message' <<<"$MAN")" "0"
check    "R10-6: file mode also says a restart reverts the identity" "$(grep -c 'Any restart of solana (crash, reboot, upgrade) brings this node back on the sync' <<<"$MAN")" "1"

echo "== R10-6: staked_key_mode — offbox: the pubkey only, no staked path consulted =="
STAKED_OK=$(mkpub Staked); SHORT31="2$(printf '1%.0s' $(seq 42))"
check "fixture: the staked pubkey decodes to 32 bytes" "$(b58_len "$STAKED_OK")" "32"
check_true  "_keys_valid_pubkey32: 32 bytes"           "_keys_valid_pubkey32 $STAKED_OK"
check_false "_keys_valid_pubkey32: regex-valid, 31 bytes" "_keys_valid_pubkey32 $SHORT31"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set solana_home "$WORK/home"
state_set staked_keypair "$WORK/home/mainnet-validator-keypair.json"     # left from an earlier file-mode run
unset SYNC_IDENTITY STAKED_KEYPAIR STAKED_PUBKEY STAKED_KEY_MODE
STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
check "offbox: mode recorded"                       "$(state_get staked_key_mode)" "offbox"
check "offbox: staked pubkey recorded"              "$(state_get staked_pubkey)" "$STAKED_OK"
check "offbox: no staked keypair path in state"     "$(state_get staked_keypair '<unset>')" "<unset>"
check "offbox: STAKED_KEYPAIR empty"                "${STAKED_KEYPAIR:-<empty>}" "<empty>"
# A staked path handed in from the environment (or a conf) is dropped, not kept.
STAKED_KEYPAIR="$WORK/home/mainnet-validator-keypair.json"
STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
check "offbox: STAKED_KEYPAIR from the environment is emptied" "${STAKED_KEYPAIR:-<empty>}" "<empty>"
( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$SHORT31" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config ) >/dev/null 2>&1
check "offbox: a 31-byte pubkey -> fail"            "$?" "1"
( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$VOTE" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config ) >/dev/null 2>&1
check "offbox: staked == vote -> fail"              "$?" "1"
( rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; unset STAKED_PUBKEY
  STAKED_KEY_MODE=offbox VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config ) >/dev/null 2>&1
check "offbox, non-interactive, no pubkey -> fail"  "$?" "1"
( STAKED_KEY_MODE=both VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config ) >/dev/null 2>&1
check "unknown mode -> fail"                        "$?" "1"
( rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; unset STAKED_KEY_MODE STAKED_KEYPAIR
  state_set solana_home "$WORK/home"; VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
  printf '%s|%s' "$(state_get staked_key_mode)" "$STAKED_KEYPAIR" ) >"$WORK/defmode"
check "no mode given, non-interactive -> file (rc9 default)" "$(cat "$WORK/defmode")" "file|$WORK/home/mainnet-validator-keypair.json"
# Back to file from offbox: the pubkey offbox recorded is dropped until phase 5
# or dz-connect derives one from the file; file -> file keeps a derived one.
( rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; unset STAKED_KEYPAIR STAKED_PUBKEY
  state_set solana_home "$WORK/home"; state_set staked_key_mode offbox; state_set staked_pubkey "$STAKED_OK"
  STAKED_KEY_MODE=file VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
  printf '%s|%s' "$(state_get staked_key_mode)" "$(state_get staked_pubkey '<unset>')" ) >"$WORK/o2f"
check "offbox -> file: the offbox pubkey is cleared" "$(cat "$WORK/o2f")" "file|<unset>"
( rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; unset STAKED_KEYPAIR STAKED_PUBKEY
  state_set solana_home "$WORK/home"; state_set staked_key_mode file; state_set staked_pubkey "$STAKED_OK"
  STAKED_KEY_MODE=file VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
  printf '%s|%s' "$(state_get staked_key_mode)" "$(state_get staked_pubkey '<unset>')" ) >"$WORK/f2f"
check "file -> file: a derived pubkey is kept"       "$(cat "$WORK/f2f")" "file|$STAKED_OK"

# Read trap: a keypair fixture sits at the default staked path. offbox must never
# open it — every pubkey derivation is logged and none may name that path.
mkdir -p "$WORK/home"; printf '[9]' >"$WORK/home/mainnet-validator-keypair.json"
PUBLOG="$WORK/pubkey.log"; : >"$PUBLOG"
_keys_pubkey() { echo "$1" >>"$PUBLOG"; case "$1" in
    *unstaked*)                  printf '%s' "$SYNC_PUB" ;;
    *mainnet-validator-keypair*) printf '%s' "$STAKED_PUB" ;;
    *)                           printf '%s' "$(mkpub Other)" ;; esac; }
ONCHAIN=""; _keys_vote_identity() { printf '%s' "$ONCHAIN"; }
SYNC_PUB=$(mkpub Sync); STAKED_PUB=$(mkpub Filekey)
ONCHAIN="$STAKED_OK"
# The fixture path is even handed in (a stale env/conf value): offbox must ignore it.
VOUT=$( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" STAKED_KEYPAIR="$WORK/home/mainnet-validator-keypair.json" SYNC_IDENTITY="$WORK/home/unstaked-identity.json" \
        VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate 2>&1 ); VRC=$?
check "offbox validate: passes"                     "$VRC" "0"
check "offbox validate: the staked file is never opened" "$(grep -c 'mainnet-validator-keypair' "$PUBLOG")" "0"
check "offbox validate: no 'key already exists' warning" "$(grep -c 'already exists at the real-key path' <<<"$VOUT")" "0"
check "offbox validate: vote account names the staked pubkey -> ok" "$(grep -c 'names the staked identity on-chain' <<<"$VOUT")" "1"
ONCHAIN=$(mkpub Elsewhere)
VOUT=$( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" SYNC_IDENTITY=/x/unstaked.json VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate 2>&1 ); VRC=$?
check "offbox validate: on-chain identity differs -> WARN, not fail" "$VRC|$(grep -c "\[WARN\].*names $(mkpub Elsewhere) as its validator identity" <<<"$VOUT")" "0|1"
ONCHAIN=""
VOUT=$( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" SYNC_IDENTITY=/x/unstaked.json VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate 2>&1 ); VRC=$?
check "offbox validate: RPC silent -> info, passes" "$VRC|$(grep -c 'Vote account not read' <<<"$VOUT")|$(grep -c '\[WARN\]' <<<"$VOUT")" "0|1|0"
( STAKED_KEY_MODE=offbox STAKED_PUBKEY="$SYNC_PUB" SYNC_IDENTITY=/x/unstaked.json VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate ) >/dev/null 2>&1
check "offbox validate: staked pubkey == sync -> FAIL" "$?" "1"
# file mode: the pubkey is derived from the file anyway — record it, check it on-chain.
state_clear staked_pubkey
ONCHAIN="$STAKED_PUB"
VOUT=$( STAKED_KEY_MODE=file STAKED_KEYPAIR="$WORK/home/mainnet-validator-keypair.json" SYNC_IDENTITY=/x/unstaked.json \
        VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate 2>&1 ); VRC=$?
check "file validate: derived pubkey recorded"      "$VRC|$(state_get staked_pubkey)" "0|$STAKED_PUB"
check "file validate: checked on-chain too"         "$(grep -c 'names the staked identity on-chain' <<<"$VOUT")" "1"

: >"$CALLS"
STAKED_KEY_MODE=offbox STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json SYNC_IDENTITY=/root/solana/unstaked-identity.json keys_config_cli >/dev/null 2>&1
check "offbox CLI config: default keypair = sync identity" "$(grep -c -- '--keypair /root/solana/unstaked-identity.json' "$CALLS")" "1"
check "offbox CLI config: no staked path"           "$(grep -c 'mainnet-validator-keypair' "$CALLS")" "0"

MAN=$(STAKED_KEY_MODE=offbox STAKED_PUBKEY="$STAKED_OK" STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json SOLANA_BIN=/opt/bin \
      LEDGER_PATH=/root/solana/ledger keys_print_manual 2>&1)
check "offbox manual: says DeePloy does not read the key" "$(grep -c 'DeePloy does not read the staked key' <<<"$MAN")" "1"
check "offbox manual: names the staked pubkey"      "$(grep -c "$STAKED_OK" <<<"$MAN")" "1"
check "offbox manual: set-identity on stdin over ssh" "$(grep -c "ssh <this-box> 'sudo -n /opt/bin/agave-validator --ledger /root/solana/ledger set-identity --require-tower' < staked.json" <<<"$MAN")" "1"
check "offbox manual: authorized-voter on stdin"    "$(grep -c "ssh <this-box> 'sudo -n /opt/bin/agave-validator --ledger /root/solana/ledger authorized-voter add' < staked.json" <<<"$MAN")" "1"
check "offbox manual: ssh stays without -t"         "$(grep -c 'Keep ssh without -t: the key must reach agave-validator through a pipe, not a terminal.' <<<"$MAN")" "1"
check "offbox manual: a restart reverts the identity" "$(grep -c 'Any restart of solana (crash, reboot, upgrade) brings this node back on the sync' <<<"$MAN")" "1"
check "offbox manual: tower step kept"              "$(grep -c 'tower-1_9-<staked-pubkey>.bin <this-box>:/root/solana/ledger/' <<<"$MAN")" "1"
check "offbox manual: no staked keypair path at all" "$(grep -c 'mainnet-validator-keypair' <<<"$MAN")" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
