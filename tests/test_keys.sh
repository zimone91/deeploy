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

# Mocked wrappers
FAKE_PUB=$(mkpub Fake); UNSTAKED_PUB=$(mkpub Unstaked); STAKED_PUB=$(mkpub Staked)
_keys_keygen_new() { echo "keygen $1" >>"$KEYGEN"; printf '[1,2,3]' >"$1"; }
_keys_pubkey() { case "$1" in
    *mvkfake*)                   printf '%s' "$FAKE_PUB" ;;
    *unstaked*)                  printf '%s' "$UNSTAKED_PUB" ;;
    *mainnet-validator-keypair*) printf '%s' "$STAKED_PUB" ;;
    *)                           printf '%s' "$(mkpub Other)" ;; esac; }
_keys_solana() { echo "solana $*" >>"$CALLS"; }

echo "== _keys_valid_pubkey =="
check_true  "valid 43-char base58" "_keys_valid_pubkey $(mkpub Abc)"
check_false "too short"            "_keys_valid_pubkey abc"
check_false "contains 0"           "_keys_valid_pubkey 0$(mkpub Abc)"

echo "== resolve_config: paths + vote validation =="
state_set solana_home "$WORK/home"
unset FAKE_IDENTITY UNSTAKED_KEYPAIR STAKED_KEYPAIR
VOTE_ACCOUNT_PUBKEY="$VOTE" keys_resolve_config >/dev/null 2>&1
check "fake path"     "$FAKE_IDENTITY"    "$WORK/home/mvkfake/mainnet-validator-keypair.json"
check "unstaked path" "$UNSTAKED_KEYPAIR" "$WORK/home/unstaked-identity.json"
check "staked path"   "$STAKED_KEYPAIR"   "$WORK/home/mainnet-validator-keypair.json"
check "vote recorded" "$(state_get vote_account_pubkey)" "$VOTE"
( VOTE_ACCOUNT_PUBKEY="bad!key" keys_resolve_config ) >/dev/null 2>&1
check "invalid vote -> fail" "$?" "1"

echo "== generate: fake+unstaked only, real key NEVER generated, idempotent =="
: >"$KEYGEN"; rm -rf "${WORK:?}/home"
FAKE_IDENTITY="$WORK/home/mvkfake/mainnet-validator-keypair.json" \
UNSTAKED_KEYPAIR="$WORK/home/unstaked-identity.json" keys_generate >/dev/null 2>&1
check "exactly 2 keygens (fake+unstaked)" "$(wc -l <"$KEYGEN" | tr -d ' ')" "2"
check "fake keygen issued"      "$(grep -c 'mvkfake' "$KEYGEN")"   "1"
check "unstaked keygen issued"  "$(grep -c 'unstaked' "$KEYGEN")"  "1"
check_true "fake file created"  "[[ -f \"$WORK/home/mvkfake/mainnet-validator-keypair.json\" ]]"
check_false "real key NOT created" "[[ -f \"$WORK/home/mainnet-validator-keypair.json\" ]]"
: >"$KEYGEN"
FAKE_IDENTITY="$WORK/home/mvkfake/mainnet-validator-keypair.json" \
UNSTAKED_KEYPAIR="$WORK/home/unstaked-identity.json" keys_generate >/dev/null 2>&1
check "idempotent: no regen when present" "$(wc -l <"$KEYGEN" | tr -d ' ')" "0"

echo "== validate: foolproofing =="
FAKE_PUB=$(mkpub Fake); UNSTAKED_PUB=$(mkpub Fake)   # same!
( FAKE_IDENTITY=/x/mvkfake/k.json UNSTAKED_KEYPAIR=/x/unstaked.json STAKED_KEYPAIR=/x/none \
  VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate ) >/dev/null 2>&1
check "fake==unstaked -> FAIL" "$?" "1"
FAKE_PUB=$(mkpub Vote)                                # identity == vote
( FAKE_IDENTITY=/x/mvkfake/k.json UNSTAKED_KEYPAIR=/x/unstaked.json STAKED_KEYPAIR=/x/none \
  VOTE_ACCOUNT_PUBKEY="$(mkpub Vote)" keys_validate ) >/dev/null 2>&1
check "vote==identity -> FAIL" "$?" "1"
FAKE_PUB=$(mkpub Fake); UNSTAKED_PUB=$(mkpub Unstaked); STAKED_PUB=$(mkpub Fake)  # staked==fake
printf '[9]' >"$WORK/mainnet-validator-keypair.json"
( FAKE_IDENTITY=/x/mvkfake/k.json UNSTAKED_KEYPAIR=/x/unstaked.json \
  STAKED_KEYPAIR="$WORK/mainnet-validator-keypair.json" VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate ) >/dev/null 2>&1
check "real-key==fake -> FAIL" "$?" "1"
FAKE_PUB=$(mkpub Fake); UNSTAKED_PUB=$(mkpub Unstaked); STAKED_PUB=$(mkpub Staked)  # all distinct
FAKE_IDENTITY=/x/mvkfake/k.json UNSTAKED_KEYPAIR=/x/unstaked.json STAKED_KEYPAIR=/x/none \
  VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate >/dev/null 2>&1
check "all distinct -> passes" "$?" "0"

echo "== config + manual instructions =="
: >"$CALLS"
STAKED_KEYPAIR=/root/solana/mainnet-validator-keypair.json keys_config_cli >/dev/null 2>&1
check "config url mainnet"          "$(grep -c 'config set --url https://api.mainnet-beta.solana.com' "$CALLS")" "1"
check "config keypair = real path"  "$(grep -c 'config set --keypair /root/solana/mainnet-validator-keypair.json' "$CALLS")" "1"
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
