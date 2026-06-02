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
check    "set-identity path-form"            "$(grep -c 'set-identity /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "authorized-voter add path-form"    "$(grep -c 'authorized-voter add /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "NO stdin redirect form (dropped)"  "$(grep -c 'set-identity < ' <<<"$MAN")" "0"
check_ge "never-touch wording"               "$(grep -ci 'never' <<<"$MAN")" "1"
check_ge "tower-rebuild note present"        "$(grep -ci 'tower' <<<"$MAN")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
