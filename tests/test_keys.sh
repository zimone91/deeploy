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
REAL_KEYS_PUBKEY=$(declare -f _keys_pubkey)       # the real one, for the PROBE-RC-ZERO checks at the end
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
check    "set-identity path-form, no --require-tower" "$(grep -c 'set-identity /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "authorized-voter add path-form"    "$(grep -c 'authorized-voter add /root/solana/mainnet-validator-keypair.json' <<<"$MAN")" "1"
check    "NO stdin redirect form (dropped)"  "$(grep -c 'set-identity < ' <<<"$MAN")" "0"
check_ge "never-touch wording"               "$(grep -ci 'never' <<<"$MAN")" "1"
# R10-9, after Alpenglow: hot swap = the old validator stops, its vote history
# moves here, the voter goes in before the identity; the cold line carries its
# condition and the only --do-not-require-vote-history.
check    "old validator stops voting first"  "$(grep -c 'OLD validator first' <<<"$MAN")" "1"
check    "a restart of the old one comes back unstaked" "$(grep -c 'Make sure a restart of the OLD validator comes back unstaked' <<<"$MAN")" "1"
check    "vote history copied to this ledger" "$(grep -cF "ssh <this-box> 'sudo -n tee /root/solana/ledger/vote_history-<staked-pubkey>.bin.tmp >/dev/null'" <<<"$MAN")" "1"
check    "no tower file, no --require-tower" "$(grep -c 'tower-1_9' <<<"$MAN")|$(grep -c -- '--require-tower' <<<"$MAN")" "0|0"
check    "the voter goes in before the identity" \
         "$(awk '/authorized-voter add \/root\/solana\/mainnet-validator-keypair.json/ {v = NR} /set-identity \/root\/solana\/mainnet-validator-keypair.json/ {s = NR} END {print (v && s && v < s) ? "voter first" : "v=" v " s=" s}' <<<"$MAN")" "voter first"
check    "cold bring-up states its condition" "$(grep -c 'only when the old validator is stopped (no process' <<<"$MAN")|$(grep -c "and the finalized slot is past the vote account's lastVote" <<<"$MAN")" "1|1"
check    "--do-not-require-vote-history only on the cold line" "$(grep -c -- '--do-not-require-vote-history' <<<"$MAN")|$(grep -c 'step c with set-identity --do-not-require-vote-history. Never in a hot swap.' <<<"$MAN")" "1|1"
check    "no bare 'No tower transfer needed'" "$(grep -c 'No tower transfer needed' <<<"$MAN")" "0"
# R10-6 (KEYMODEL-DZ-READS): in dz-connect the key signs twice, not "one message".
check    "file mode names both dz-connect signatures" "$(grep -c 'signs the passport message and the request transaction it pays for' <<<"$MAN")" "1"
check    "no 'sign one DoubleZero passport message'"  "$(grep -c 'sign one DoubleZero passport message' <<<"$MAN")" "0"
check    "R10-6: file mode also says a restart reverts the identity" "$(grep -c 'Any restart of solana (crash, reboot, upgrade) brings this node back on the sync' <<<"$MAN")" "1"

echo "== R10-9b: the printed swap — the vote history moves once the old node has switched and the file has stopped changing; step d checks that the node votes =="
# The old node's votor rewrites vote_history-<staked-pubkey>.bin after every vote, by renaming a
# .bin.new over it, until it has handled the identity change of step a, and then logs the switch.
# Step b waits for that line, then for two equal sha256, 2 s apart, copies as root at both ends under
# a temporary name, compares, and only then moves the copy in; step d reads the file's time and the
# log, as root too. Both forms print the same b and d, so the same checks run on both.
first() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }        # <text> <fixed string> -> its first line number
increasing() { local p=0 x; for x in "$@"; do [[ -n $x && $x -gt $p ]] || return 1; p=$x; done; }
tac() { awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$@"; }    # the printed log checks on any userland
sudo() { [[ "${1:-}" == -n ]] && shift; "$@"; }                       # ... and where sudo is not at hand
swap_steps_checks() {    # <label> <printed text> <voter line> <identity line> <log path> <lines that open an ssh to this box>
    local l=$1 t=$2 vp=$3 ip=$4 lg=$5 nssh=$6 vh="/root/solana/ledger/vote_history-<staked-pubkey>.bin"
    local old="<old-ledger>/vote_history-<staked-pubkey>.bin" w s k m n e f g h cmd out SWLOG OLDLOG statl
    check "$l: b) waits until the latest set-identity line in the old node's log is the switch away from the staked key" \
          "$(grep -cF -- "ssh <old> 'sudo -n tac <old-log> | grep -m1 \"set-identity: from \" | grep \"from <staked-pubkey> to \"'" <<<"$t")" "1"
    check "$l: b) reads the old file's sha256 twice, 2 s apart" \
          "$(grep -cF -- "sha256sum $old; sleep 2; sudo -n sha256sum $old'" <<<"$t")" "1"
    check "$l: b) copies as root at both ends, to a temporary name in this ledger" \
          "$(grep -cF -- "ssh <old> 'sudo -n cat $old' | ssh <this-box> 'sudo -n tee $vh.tmp >/dev/null'" <<<"$t")" "1"
    check "$l: b) compares the copy's sha256" \
          "$(grep -cF -- "ssh <this-box> 'sudo -n sha256sum $vh.tmp'" <<<"$t")" "1"
    check "$l: b) moves the copy into place" \
          "$(grep -cF -- "ssh <this-box> 'sudo -n mv $vh.tmp $vh'" <<<"$t")" "1"
    check "$l: b) nothing is written to the final name but by the mv, and no scp" \
          "$(grep -F -- "tee $vh" <<<"$t" | grep -cvF -- "$vh.tmp")|$(grep -c 'scp ' <<<"$t")" "0|0"
    check "$l: the printed text opens $nssh ssh connections to this box" "$(grep -c 'ssh <this-box> ' <<<"$t")" "$nssh"
    check "$l: d) is its own step, on this box, after c" "$(grep -cF -- 'd) On this box' <<<"$t")" "1"
    # shellcheck disable=SC2016    # the printed line carries a literal $( ) and $t
    statl='t=$(sudo -n stat -c %y '"$vh"'); sleep 15; [ "$(sudo -n stat -c %y '"$vh"')" != "$t" ] && echo VOTING || echo NOT-VOTING'
    check "$l: d) the file's time, read as root, must move within about 15 s" "$(grep -cF -- "$statl" <<<"$t")" "1"
    check "$l: d) the file check is valid shell" \
          "$(bash -n <<<"$(grep -F 'sleep 15;' <<<"$t" | sed 's/^ *//')" 2>&1; echo "rc=$?")" "rc=0"
    check "$l: d) the log is read as root, backwards, from the state's solana_home, up to its latest set-identity line" \
          "$(grep -cF -- "sudo -n tac $lg | awk '/set-identity: from / {s=1; f = (\$0 ~ / to <staked-pubkey>/); exit} " <<<"$t")" "1"
    check "$l: d) the three lines of a node that does not vote" \
          "$(grep -cF -- '/Failed to generate vote message|No authorized voter keypair matches|Rank-map node pubkey mismatch/ {n++; print}' <<<"$t")" "1"
    w=$(first "$t" "sudo -n tac <old-log>"); s=$(first "$t" "; sleep 2; sudo -n sha256sum <old-ledger>")
    k=$(first "$t" "<this-box> 'sudo -n tee $vh.tmp"); m=$(first "$t" "ssh <this-box> 'sudo -n sha256sum $vh.tmp'")
    n=$(first "$t" "ssh <this-box> 'sudo -n mv $vh.tmp $vh'"); e=$(first "$t" "$vp"); f=$(first "$t" "$ip")
    g=$(first "$t" "stat -c %y"); h=$(first "$t" "sudo -n tac $lg")
    check "$l: order — the switch line, settle, copy, compare, move, voter, identity, the file check, the log check" \
          "$( increasing "$w" "$s" "$k" "$m" "$n" "$e" "$f" "$g" "$h" && echo ordered || echo "w=$w s=$s k=$k m=$m n=$n e=$e f=$f g=$g h=$h")" "ordered"
    # The wait for the old node's switch, run on logs. The LATEST set-identity line must read "from <staked> to <anything>".
    # The line that put the old node on the staked identity ("from <sync> to <staked>") is not the signal, and neither is an
    # older switch away from it with the switch back onto the staked key above it: the first line of that direction would pass
    # the wait before votor has handled step a.
    OLDLOG="$WORK/old-log"
    cmd=$(grep -F 'tac <old-log>' <<<"$t" | head -1 | sed -E "s/^ *ssh <old> '(.*)'\$/\\1/"); cmd=${cmd//<old-log>/$OLDLOG}; cmd=${cmd//<staked-pubkey>/$STAKED_PUB}
    {   echo "set-identity: from $SYNC_PUB to $STAKED_PUB"; echo "a vote went out"; } >"$OLDLOG"
    check "$l: b) the wait, while the old node is still on the staked identity: nothing printed" "$(eval "$cmd" 2>&1 | grep -c .)" "0"
    {   echo "set-identity: from $STAKED_PUB to $SYNC_PUB"; echo "set-identity: from $SYNC_PUB to $STAKED_PUB"; echo "a vote went out"; } >"$OLDLOG"
    check "$l: b) the wait, an older switch away from the staked key under the latest switch onto it: nothing printed" "$(eval "$cmd" 2>&1 | grep -c .)" "0"
    echo "set-identity: from $STAKED_PUB to $SYNC_PUB" >>"$OLDLOG"
    check "$l: b) the wait, after its switch: the line prints" "$(eval "$cmd" 2>&1)" "set-identity: from $STAKED_PUB to $SYNC_PUB"
    # The printed log check, run on logs: what is above the latest set-identity line is not the swap's, and that line must be the
    # switch onto the staked key; with another switch as the latest line votor has not handled step c yet, and nothing is counted.
    SWLOG="$WORK/swap-log"
    cmd=$(grep -F -- "sudo -n tac $lg | awk" <<<"$t" | head -1 | sed 's/^ *//'); cmd=${cmd//"$lg"/$SWLOG}; cmd=${cmd//<staked-pubkey>/$STAKED_PUB}
    {   echo "Failed to generate vote message: NonVoting"
        echo "Rank-map node pubkey mismatch: rank=7; expected=$STAKED_PUB; got=$SYNC_PUB"
        echo "set-identity: from $SYNC_PUB to $STAKED_PUB"
        echo "Failed to generate vote message: after an older switch"
        echo "set-identity: from $SYNC_PUB to $STAKED_PUB"
        echo "a vote went out"; } >"$SWLOG"
    out=$(eval "$cmd" 2>&1)
    check "$l: d) the log check, clean after the latest switch (bad lines above it do not count)" "$out" "0 such lines after the switch"
    echo "Rank-map node pubkey mismatch: rank=7; expected=$STAKED_PUB; got=$SYNC_PUB" >>"$SWLOG"
    out=$(eval "$cmd" 2>&1)
    check "$l: d) the log check, one bad line after the switch" "$(grep -c 'Rank-map node pubkey mismatch' <<<"$out")|$(tail -1 <<<"$out")" "1|1 such lines after the switch"
    {   echo "set-identity: from $SYNC_PUB to $STAKED_PUB"
        echo "Failed to generate vote message: while staked"
        echo "set-identity: from $STAKED_PUB to $SYNC_PUB"
        echo "Rank-map node pubkey mismatch: rank=7; expected=$STAKED_PUB; got=$SYNC_PUB"; } >"$SWLOG"
    out=$(eval "$cmd" 2>&1)
    check "$l: d) the log check, the latest set-identity line is another switch: it says to wait" \
          "$(tail -1 <<<"$out")" "the latest set-identity line is not the switch to $STAKED_PUB: wait, run it again"
    echo "set-identity: from $SYNC_PUB to $STAKED_PUB" >>"$SWLOG"
    out=$(eval "$cmd" 2>&1)
    check "$l: d) the log check, once the switch onto the staked key is the latest line: clean" "$out" "0 such lines after the switch"
    {   echo "Failed to generate vote message: NonVoting"; echo "a vote went out"; } >"$SWLOG"
    out=$(eval "$cmd" 2>&1)
    check "$l: d) the log check, no set-identity line at all" "$(tail -1 <<<"$out")" "no set-identity line in the log"
}
# the log is the one validatorcfg renders: SOLANA_HOME from the state (lib/validatorcfg.sh:32), whatever the environment says
HOME_BEFORE=$(state_get solana_home "")
state_set solana_home /srv/sol
SWAP_FILE=$(keys_print_swap_steps agave-validator /root/solana/ledger /root/solana/mainnet-validator-keypair.json 2>&1)
swap_steps_checks "file" "$SWAP_FILE" "authorized-voter add /root/solana/mainnet-validator-keypair.json" \
                  "set-identity /root/solana/mainnet-validator-keypair.json" /srv/sol/solana.log 3
SWAP_OFF=$(keys_print_swap_steps /opt/bin/agave-validator /root/solana/ledger 2>&1)
swap_steps_checks "offbox" "$SWAP_OFF" "authorized-voter add' < staked.json" "set-identity' < staked.json" /srv/sol/solana.log 5
check "the log path comes from the state, not from the environment: SOLANA_HOME=/env/other changes nothing" \
      "$( SOLANA_HOME=/env/other keys_print_swap_steps agave-validator /root/solana/ledger 2>&1 | grep -cF 'sudo -n tac /srv/sol/solana.log | awk')" "1"
state_clear solana_home
check "no solana_home in the state: /root/solana/solana.log, as validatorcfg" \
      "$( unset SOLANA_HOME; keys_print_swap_steps agave-validator /root/solana/ledger 2>&1 | grep -cF 'sudo -n tac /root/solana/solana.log | awk')" "1"
[[ -n "$HOME_BEFORE" ]] && state_set solana_home "$HOME_BEFORE"
unset -f sudo tac
# tests/test_docs.sh checks anchors only: the sentences in KEY-MODEL items 3 and 6 are checked here, with the code they describe
KM="$ROOT/docs/KEY-MODEL.md"
KMJ=$(tr '\n' ' ' <"$KM" | tr -s ' ')                    # the sentences wrap in the file
check "KEY-MODEL: the copy waits until the old node's latest set-identity line is the switch away from the staked key, and for two equal sha256, and moves in under a temporary name" \
      "$(grep -cF "the copy waits until the latest \`set-identity:\` line in the old node's log reads \`from <staked-pubkey> to …\` and until two sha256 readings 2 s apart agree" <<<"$KMJ")|$(grep -cF "is moved into place when its sha256 matches the source's" <<<"$KMJ")" "1|1"
check "KEY-MODEL: the file must change within about 15 s, and the three log lines after the latest set-identity line" \
      "$(grep -cF 'the file in this ledger must change within about 15 s' <<<"$KMJ")|$(grep -cF "none of \`Failed to generate vote message\`, \`No authorized voter keypair matches\` or \`Rank-map node pubkey mismatch\` after its latest \`set-identity:\` line, which must be the switch to the staked key" <<<"$KMJ")" "1|1"
check "KEY-MODEL: the connection count of the offbox steps is the printed text's, five, and step d a sixth" \
      "$(grep -c 'ssh <this-box> ' <<<"$SWAP_OFF")|$(grep -cF "the printed \`offbox\` steps alone make five connections to the box, and step d's login a sixth" <<<"$KMJ")" "5|1"

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
check "offbox manual: set-identity on stdin over ssh" "$(grep -c "ssh <this-box> 'sudo -n /opt/bin/agave-validator --ledger /root/solana/ledger set-identity' < staked.json" <<<"$MAN")" "1"
check "offbox manual: authorized-voter on stdin"    "$(grep -c "ssh <this-box> 'sudo -n /opt/bin/agave-validator --ledger /root/solana/ledger authorized-voter add' < staked.json" <<<"$MAN")" "1"
check "offbox manual: the voter goes in before the identity" \
      "$(awk "/authorized-voter add' < staked.json/ {v = NR} /set-identity' < staked.json/ {s = NR} END {print (v && s && v < s) ? \"voter first\" : \"v=\" v \" s=\" s}" <<<"$MAN")" "voter first"
check "offbox manual: ssh stays without -t"         "$(grep -c 'Keep ssh without -t: the key must reach agave-validator through a pipe, not a terminal.' <<<"$MAN")" "1"
check "offbox manual: a restart reverts the identity" "$(grep -c 'Any restart of solana (crash, reboot, upgrade) brings this node back on the sync' <<<"$MAN")" "1"
check "offbox manual: vote history step kept"      "$(grep -cF "ssh <this-box> 'sudo -n tee /root/solana/ledger/vote_history-<staked-pubkey>.bin.tmp >/dev/null'" <<<"$MAN")" "1"
check "offbox manual: no staked keypair path at all" "$(grep -c 'mainnet-validator-keypair' <<<"$MAN")" "0"

echo "== PROBE-RC-ZERO: the real _keys_pubkey answers 0 inside \$( ) =="
# The checks above mock _keys_pubkey; these put the real one back, over a fake
# solana-keygen that fails on a file it cannot read as a keypair. The sync and
# staked reads are bare assignments, where that failure ended the run with a raw
# ERR line before DeePloy's own refusal could say anything.
KB="$WORK/rc0bin"; KD="$WORK/rc0"; mkdir -p "$KB" "$KD"
cat >"$KB/solana-keygen" <<'EOF'
#!/bin/sh
# fake: 'pubkey <file>' prints what follows "pub:" in the file; anything else fails
[ "$1" = pubkey ] && grep -q '^pub:' "$2" 2>/dev/null || { echo "Error: not a keypair: $2" >&2; exit 1; }
sed -n 's/^pub://p' "$2"
EOF
chmod +x "$KB/solana-keygen"
printf 'pub:%s\n' "$(mkpub Sync)"   >"$KD/unstaked-identity.json"
printf 'pub:%s\n' "$(mkpub Staked)" >"$KD/mainnet-validator-keypair.json"
printf 'not a keypair\n'            >"$KD/bad.json"
ONCHAIN=""
rc0_validate() {                                  # <sync identity> <staked mode> <staked keypair> -> output, then rc=N
    ( eval "$REAL_KEYS_PUBKEY"; set -Eeuo pipefail; deeploy_init_traps; trap - EXIT
      SOLANA_BIN="$KB" SYNC_IDENTITY=$1 STAKED_KEY_MODE=$2 STAKED_KEYPAIR=$3 STAKED_PUBKEY=$(mkpub Remote) \
        VOTE_ACCOUNT_PUBKEY="$VOTE" keys_validate ) 2>&1
    echo "rc=$?"
}
stray() { grep -cE '\[FAIL\] line [0-9]+:' <<<"$1"; }
OUT=$(rc0_validate "$KD/bad.json" file "$KD/absent.json")
check "PROBE-RC-ZERO: unreadable sync identity -> its own refusal, alone" \
      "$(grep -cx 'rc=1' <<<"$OUT")|$(stray "$OUT")|$(grep -cF "Could not read sync-identity pubkey from $KD/bad.json" <<<"$OUT")" "1|0|1"
OUT=$(rc0_validate "$KD/unstaked-identity.json" file "$KD/bad.json")
check "PROBE-RC-ZERO: unreadable key at the real-key path (file) -> refused, alone, no 'checks passed'" \
      "$(grep -cx 'rc=1' <<<"$OUT")|$(stray "$OUT")|$(grep -cF "Could not read a pubkey from the key at the real-key path ($KD/bad.json)" <<<"$OUT")|$(grep -c 'Identity checks passed' <<<"$OUT")" "1|0|1|0"
OUT=$(rc0_validate "$KD/unstaked-identity.json" file "$KD/mainnet-validator-keypair.json")
check "  control: a readable key at the real-key path -> passes, its pubkey recorded" \
      "$(grep -cx 'rc=0' <<<"$OUT")|$(stray "$OUT")|$(grep -c 'Identity checks passed' <<<"$OUT")|$(state_get staked_pubkey)" "1|0|1|$(mkpub Staked)"
OUT=$(rc0_validate "$KD/unstaked-identity.json" file "$KD/absent.json")
check "  control: file mode, nothing at the real-key path -> passes" \
      "$(grep -cx 'rc=0' <<<"$OUT")|$(stray "$OUT")|$(grep -c 'Identity checks passed' <<<"$OUT")" "1|0|1"
OUT=$(rc0_validate "$KD/unstaked-identity.json" offbox "$KD/bad.json")
check "  control: offbox, an unreadable file at that path is not read -> passes" \
      "$(grep -cx 'rc=0' <<<"$OUT")|$(stray "$OUT")|$(grep -c 'Identity checks passed' <<<"$OUT")" "1|0|1"
# An argument, not an assignment: the run went on, with a stray ERR line.
OUT=$( ( eval "$REAL_KEYS_PUBKEY"; set -Eeuo pipefail; deeploy_init_traps; trap - EXIT
         SOLANA_BIN="$KB" _keys_generate_one "$KD/bad.json" "Unstaked sync identity" ) 2>&1 ); RC=$?
check "PROBE-RC-ZERO: a present key solana-keygen cannot read -> kept, no stray [FAIL] line" \
      "$RC|$(stray "$OUT")|$(grep -c 'Unstaked sync identity already present' <<<"$OUT")" "0|0|1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
