#!/usr/bin/env bash
# Self-contained tests for lib/config.sh — export/import round-trip, the
# no-key-material guard, validation, and opt-in --rescore.
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
export CONFIG_FILE="$WORK/deeploy.conf"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# constants.sh: the shipped example must satisfy our own DEEPLOY_MIN_JITO_TAG
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# base.sh / keys.sh provide _valid_port and _keys_valid_pubkey, reused by the
# config type-validators (production sources all modules; mirror that here).
# shellcheck source-path=SCRIPTDIR source=../lib/base.sh
source "$ROOT/lib/base.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/keys.sh
source "$ROOT/lib/keys.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/config.sh
source "$ROOT/lib/config.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
# lines_with <substring> <text> — every line of <text> containing it, whole
lines_with()  { local l; while IFS= read -r l; do [[ "$l" == *"$1"* ]] && printf '%s\n' "$l"; done <<<"$2"; }

DRY_RUN=0 common_init
VOTE="Vote1111111111111111111111111111111111111111"

seed_state() {
    rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
    state_set ssh_port 2222
    state_set xdp_cores_count 2;          state_set xdp_cores 1-2
    state_set isolated_set "1-2,25-26"
    state_set nic_driver mlx5_core;       state_set retransmit_supported 1; state_set retransmit_zero_copy 1
    state_set disk_layout two-nvme;       state_set ledger_disk /dev/nvme0n1; state_set accounts_disk /dev/nvme1n1
    state_set data_layout two-nvme        # this box's own record: never exported (R10-7b)
    state_set solana_home /root/solana;   state_set ledger_path /root/solana/ledger
    state_set accounts_path /mnt/accounts/solana/accounts; state_set snapshots_path /root/solana/snapshots
    state_set jito_tag v4.0.0-jito
    state_set sync_identity /root/solana/unstaked-identity.json
    state_set staked_keypair /root/solana/mainnet-validator-keypair.json
    state_set vote_account_pubkey "$VOTE"
    state_set mev_mode bam; state_set bam_url http://slc.mainnet.bam.jito.wtf
    state_set block_engine_url https://slc.mainnet.block-engine.jito.wtf
    state_set shred_receiver 64.130.53.8:1002; state_set commission_bps 0
    state_set dz_enabled true; state_set dz_env mainnet-beta
    state_set dz_keypair /root/solana/dz-keypair.json
}

echo "== export: content, no key material, chmod 600 =="
seed_state
state_set poh_core 10                 # an older install's state still has it
config_export >/dev/null 2>&1
check_true "conf written"           "[[ -f \"$CONFIG_FILE\" ]]"
check "SSH_PORT"                    "$(grep -c 'SSH_PORT=\"2222\"' "$CONFIG_FILE")" "1"
check "POH_CORE is no longer exported (an older install's state still has poh_core)" "$(grep -c 'POH_CORE' "$CONFIG_FILE")" "0"
check "the XDP cores and the isolated set are"   "$(grep -c 'XDP_CORES_COUNT=\"2\"' "$CONFIG_FILE")|$(grep -c 'XDP_CORES=\"1-2\"' "$CONFIG_FILE")|$(grep -c 'ISOLATED_SET=\"1-2,25-26\"' "$CONFIG_FILE")" "1|1|1"
check "JITO_TAG"                    "$(grep -c 'JITO_TAG=\"v4.0.0-jito\"' "$CONFIG_FILE")" "1"
check "STAKED_KEYPAIR is a PATH"    "$(grep -c 'STAKED_KEYPAIR=\"/root/solana/mainnet-validator-keypair.json\"' "$CONFIG_FILE")" "1"
# sync_identity (state) exports under the file-based conf key UNSTAKED_KEYPAIR; no FAKE_IDENTITY key anymore.
check "sync_identity -> UNSTAKED_KEYPAIR conf key" "$(grep -c 'UNSTAKED_KEYPAIR=\"/root/solana/unstaked-identity.json\"' "$CONFIG_FILE")" "1"
check "no FAKE_IDENTITY_KEYPAIR key (mvkfake gone)" "$(grep -c 'FAKE_IDENTITY' "$CONFIG_FILE")" "0"
check "VOTE pubkey (public)"        "$(grep -c "VOTE_ACCOUNT_PUBKEY=\"$VOTE\"" "$CONFIG_FILE")" "1"
check "BAM/region captured"         "$(grep -c 'BAM_URL=\"http://slc.mainnet.bam.jito.wtf\"' "$CONFIG_FILE")" "1"
check "NO key material (JSON array)" "$(grep -cE '\[[0-9]+,[0-9]+' "$CONFIG_FILE")" "0"
check "data_layout not exported (it says nothing about another box's disks)" "$(grep -ci 'data_layout' "$CONFIG_FILE")" "0"
check "NO .json contents leaked"    "$(grep -cE '^\[|,[0-9]+,[0-9]+,' "$CONFIG_FILE")" "0"
# shellcheck disable=SC2012  # ls is fine here; portable perm read for the test
check "chmod 600"                   "$(ls -l "$CONFIG_FILE" | cut -c1-10)" "-rw-------"
check "DeePloy version stamped in header" "$(grep -c '# Created with DeePloy v' "$CONFIG_FILE")" "1"
# Fix #2 completeness (adversarial-review finding): the header provenance line must
# use a RUNNABLE command (./deeploy.sh export, via DEEPLOY_CMD), never bare 'deeploy export'.
check "header: NO bare 'deeploy export'" "$(grep -cE "generated by 'deeploy export'" "$CONFIG_FILE")" "0"
check "header: runnable export command"  "$(grep -cE "generated by '(\./deeploy\.sh|/.*deeploy\.sh) export'" "$CONFIG_FILE")" "1"

echo "== validate: rejects key material / missing keys / bad pubkey =="
cp "$CONFIG_FILE" "$WORK/mat.conf"; echo 'LEAK="[174,12,99]"' >>"$WORK/mat.conf"
( _config_validate "$WORK/mat.conf" ) >/dev/null 2>&1; check "key material -> reject" "$?" "1"
grep -v '^JITO_TAG=' "$CONFIG_FILE" >"$WORK/nojito.conf"
( _config_validate "$WORK/nojito.conf" ) >/dev/null 2>&1; check "missing JITO_TAG -> reject" "$?" "1"
sed 's/^VOTE_ACCOUNT_PUBKEY=.*/VOTE_ACCOUNT_PUBKEY="bad!key"/' "$CONFIG_FILE" >"$WORK/badvote.conf"
( _config_validate "$WORK/badvote.conf" ) >/dev/null 2>&1; check "bad pubkey -> reject" "$?" "1"
( _config_validate "$CONFIG_FILE" ) >/dev/null 2>&1; check "valid conf -> accept" "$?" "0"

echo "== import: validate -> load into state =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
RESCORE=0 config_import >/dev/null 2>&1
check "nothing recorded as poh_core"  "$(state_get poh_core '<none>')" "<none>"
check "imported xdp_cores_count"       "$(state_get xdp_cores_count)" "2"
check "imported vote"       "$(state_get vote_account_pubkey)" "$VOTE"
check "imported staked path" "$(state_get staked_keypair)" "/root/solana/mainnet-validator-keypair.json"
check "imported sync_identity (round-trips via UNSTAKED_KEYPAIR)" "$(state_get sync_identity)" "/root/solana/unstaked-identity.json"
check "imported bam_url"    "$(state_get bam_url)" "http://slc.mainnet.bam.jito.wtf"

echo "== region: --rescore INVOKES region_recommend; plain import does NOT =="
RC="$WORK/regioncalls"
region_recommend() { echo called >>"$RC"
                     state_set suggested_bam_url http://ny.mainnet.bam.jito.wtf
                     state_set suggested_block_engine_url https://ny.mainnet.block-engine.jito.wtf
                     state_set suggested_shred_receiver 141.98.216.96:1002; }
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; : >"$RC"
RESCORE=0 config_import >/dev/null 2>&1
check "plain import does NOT call region_recommend" "$(wc -l <"$RC" | tr -d ' ')" "0"
check "plain import keeps stored bam"               "$(state_get bam_url)" "http://slc.mainnet.bam.jito.wtf"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; : >"$RC"
RESCORE=1 config_import >/dev/null 2>&1
check "--rescore DID call region_recommend"  "$(wc -l <"$RC" | tr -d ' ')" "1"
check "--rescore overrides bam_url"          "$(state_get bam_url)" "http://ny.mainnet.bam.jito.wtf"
check "--rescore overrides shred"            "$(state_get shred_receiver)" "141.98.216.96:1002"

echo "== export stamps the RECORDED build version (state, not just the live constant) =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
state_set deeploy_version 0.9.9
CONFIG_FILE="$WORK/ver.conf" config_export >/dev/null 2>&1
check "export header shows recorded version 0.9.9" "$(grep -c '# Created with DeePloy v0.9.9' "$WORK/ver.conf")" "1"

echo "== S2: typed parser executes NOTHING (parse, never source/eval) =="
# Each payload is written LITERALLY: printf's format is a single-quoted string,
# so $(...), backticks and ; are data, and only %s (=$WORK) expands. Re-using the
# expanded value as a printf format is safe — the metacharacters are not format
# directives, so they reach the parser verbatim.
parse_noexec() {   # <desc> <printf-fmt with one %s for $WORK>
    local desc=$1 fmt=$2 rc
    rm -f "$WORK/pwned"
    # shellcheck disable=SC2059
    printf "$fmt"'\n' "$WORK" > "$WORK/evil.conf"
    ( _config_parse_safe "$WORK/evil.conf" ) >/dev/null 2>&1; rc=$?
    check "$desc: rejected (rc 1)"                 "$rc" "1"
    check_true "$desc: NO side effect (no sentinel)" "[[ ! -e \"$WORK/pwned\" ]]"
}
parse_noexec "semicolon+touch" 'SSH_PORT="22; touch %s/pwned"'
# SC2016: the $(...) / backticks are LITERAL injection payloads, kept unexpanded on purpose.
# shellcheck disable=SC2016
parse_noexec "command-subst"   'BAM_URL="http://x$(touch %s/pwned)"'
# shellcheck disable=SC2016
parse_noexec "backticks"       'LEDGER_PATH="/x`touch %s/pwned`"'
parse_noexec "rm-injection"    'STAKED_KEYPAIR="/a;rm -rf %s/pwned"'
# A value with an embedded newline + a second KEY= line must not execute either.
rm -f "$WORK/pwned"
printf 'SSH_PORT="22\nLEDGER_PATH=/x; touch %s/pwned"\n' "$WORK" > "$WORK/evil.conf"
( _config_parse_safe "$WORK/evil.conf" ) >/dev/null 2>&1
check_true "newline-injection: NO side effect" "[[ ! -e \"$WORK/pwned\" ]]"

echo "== S2: config_import on a poisoned conf aborts and runs nothing =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; seed_state
config_export >/dev/null 2>&1                       # a VALID base conf
rm -f "$WORK/pwned"
printf 'SSH_PORT="22; touch %s/pwned"\n' "$WORK" >> "$CONFIG_FILE"   # append a poisoned override
( RESCORE=0 config_import ) >/dev/null 2>&1; rc=$?
check_true "import aborts (non-zero)"        "[[ \"$rc\" != \"0\" ]]"
check_true "import ran NO injected code"     "[[ ! -e \"$WORK/pwned\" ]]"

echo "== S2: type validation rejects malformed values =="
type_reject() {   # <desc> <conf line, no %>
    local desc=$1 line=$2 rc
    printf '%s\n' "$line" > "$WORK/t.conf"
    ( _config_parse_safe "$WORK/t.conf" ) >/dev/null 2>&1; rc=$?
    check "$desc -> rejected" "$rc" "1"
}
type_reject "port out of range"  'SSH_PORT="70000"'
type_reject "bad pubkey charset" 'VOTE_ACCOUNT_PUBKEY="bad!key"'
type_reject "int with exponent"  'COMMISSION_BPS="1e9"'
type_reject "cores with inject"  'XDP_CORES="1-2;x"'
type_reject "url with space"     'BAM_URL="http://x y"'
type_reject "ip non-numeric"     'RPC_BIND_ADDRESS="localhost"'
type_reject "portrange reversed" 'DYNAMIC_PORT_RANGE="9000-8900"'
type_reject "portrange bad port" 'DYNAMIC_PORT_RANGE="10-70000"'
type_reject "bps over 10000"     'COMMISSION_BPS="10001"'
type_reject "bps negative"       'COMMISSION_BPS="-1"'
type_reject "bps junk"           'COMMISSION_BPS="1e9"'
# 64-bit wraparound (adversarial-review find): bash arithmetic wraps at 2^64,
# so 2^64+10000 would pass an uncapped `<= 10000` — the digit cap must hold.
type_reject "bps 2^64 wrap"      'COMMISSION_BPS="18446744073709561616"'
type_reject "bps 6 digits"       'COMMISSION_BPS="100000"'
type_reject "R10-6: keymode not file/offbox" 'STAKED_KEY_MODE="both"'
type_reject "R10-6: staked pubkey charset" 'STAKED_PUBKEY="0OIl1111111111111111111111111111111"'

echo "== S2: VALID values of every type ACCEPTED (incl. portrange under set -u) =="
type_accept() {   # <desc> <conf line> <KEY> <expected-global>
    local desc=$1 line=$2 key=$3 want=$4
    unset "$key" 2>/dev/null || true
    printf '%s\n' "$line" > "$WORK/ok.conf"
    _config_parse_safe "$WORK/ok.conf" >/dev/null 2>&1
    check "$desc accepted -> sets global" "${!key:-<unset>}" "$want"
}
type_accept "portrange"  'DYNAMIC_PORT_RANGE="8900-9000"'   DYNAMIC_PORT_RANGE  "8900-9000"
type_accept "ip"         'RPC_BIND_ADDRESS="127.0.0.1"'     RPC_BIND_ADDRESS    "127.0.0.1"
type_accept "cores"      'XDP_CORES="1-2,25-26"'            XDP_CORES           "1-2,25-26"
type_accept "hostport"   'SHRED_RECEIVER_ADDRESS="1.2.3.4:1002"' SHRED_RECEIVER_ADDRESS "1.2.3.4:1002"
type_accept "url"        'BAM_URL="https://a.b.jito.wtf"'   BAM_URL             "https://a.b.jito.wtf"
type_accept "bool"       'DZ_ENABLED="true"'                DZ_ENABLED          "true"
type_accept "bps 0"      'COMMISSION_BPS="0"'               COMMISSION_BPS      "0"
type_accept "bps 10000"  'COMMISSION_BPS="10000"'           COMMISSION_BPS      "10000"
type_accept "R10-6: keymode offbox" 'STAKED_KEY_MODE="offbox"' STAKED_KEY_MODE "offbox"
type_accept "R10-6: keymode file"   'STAKED_KEY_MODE="file"'   STAKED_KEY_MODE "file"

echo "== S2: unknown key ignored — sets no global, parse still succeeds =="
unset EVIL 2>/dev/null || true
printf 'EVIL="x"\n' > "$WORK/u.conf"
_config_parse_safe "$WORK/u.conf" >/dev/null 2>&1; rc=$?
check "unknown key -> rc 0 (ignored)"          "$rc" "0"
check_true "unknown key creates NO global"     "[[ -z \"\${EVIL+set}\" ]]"

echo "== N12: a malformed config applies NOTHING (atomic parse-then-commit) =="
# The old parser set each valid global AS IT PARSED, then returned 1 — so the
# caller's "ignoring malformed config" message was false. Probe keys on BOTH
# sides of the bad line: neither may be applied.
unset SSH_PORT RPC_THREADS 2>/dev/null || true
printf '%s\n' 'SSH_PORT="2222"' 'BAM_URL="http://x y"' 'RPC_THREADS="12"' >"$WORK/n12.conf"
# Run in the CURRENT shell (adversarial-review fix): a $() capture is a
# subshell, so printf -v assignments could never reach these probes and the
# test passed even against the old apply-as-you-parse code. Output is captured
# in a separate run below.
_config_parse_safe "$WORK/n12.conf" >/dev/null 2>&1; N12RC=$?
check "N12: malformed file -> rc1"                        "$N12RC" "1"
check "N12: key BEFORE the bad line NOT applied"          "${SSH_PORT:-<unset>}" "<unset>"
check "N12: key AFTER the bad line NOT applied"           "${RPC_THREADS:-<unset>}" "<unset>"
N12OUT=$(_config_parse_safe "$WORK/n12.conf" 2>&1 || true)
check "N12: warn says nothing applied (message now true)" "$(grep -c 'nothing applied' <<<"$N12OUT")" "1"
# a clean file behaves exactly as before: rc0, globals set
printf '%s\n' 'SSH_PORT="2222"' 'RPC_THREADS="12"' >"$WORK/n12ok.conf"
_config_parse_safe "$WORK/n12ok.conf" >/dev/null 2>&1; N12OKRC=$?
check "N12: clean file -> rc0"                            "$N12OKRC" "0"
check "N12: clean file applies both keys"                 "${SSH_PORT:-x}/${RPC_THREADS:-x}" "2222/12"
unset SSH_PORT RPC_THREADS 2>/dev/null || true

echo "== R2: an older conf that still sets POH_CORE warns once and goes on =="
# POH_CORE was a setting of an older DeePloy and is none now: the line is ignored
# (never applied, never recorded), and a value that used to be refused is no reason to stop.
unset POH_CORE 2>/dev/null || true
for v in 10 abc 99999999999999999999 ""; do
    printf '%s\n' 'SSH_PORT="2222"' "POH_CORE=\"$v\"" >"$WORK/poh.conf"
    _config_parse_safe "$WORK/poh.conf" >"$WORK/poh.out" 2>&1; PRC=$?
    check "POH_CORE=\"$v\": parse succeeds, one warning, no global" "$PRC|$(grep -c 'POH_CORE is ignored' "$WORK/poh.out")|${POH_CORE:-<unset>}" "0|1|<unset>"
done
printf '%s\n' 'SSH_PORT="2222"' 'POH_CORE="10"' 'POH_CORE="12"' >"$WORK/poh2.conf"
_config_parse_safe "$WORK/poh2.conf" >"$WORK/poh.out" 2>&1
check "a conf that sets it twice: still one warning" "$(grep -c 'POH_CORE is ignored' "$WORK/poh.out")" "1"
printf '%s\n' 'SSH_PORT="2222"' 'RPC_THREADS="12"' >"$WORK/nopoh.conf"
_config_parse_safe "$WORK/nopoh.conf" >"$WORK/poh.out" 2>&1
check "a conf without it: no such warning" "$(grep -c 'POH_CORE' "$WORK/poh.out")" "0"
printf '%s\n' 'SSH_PORT="2222"' 'POH_CORE="10"' >"$WORK/poh.conf"
_config_parse_safe "$WORK/poh.conf" >"$WORK/poh.out" 2>&1
check "the warning gives the reason: Alpenglow and PohService, naming the pinned tag" \
      "$(grep -c "under Alpenglow jito-solana ${DEEPLOY_PIN_JITO_TAG} does not start PohService" "$WORK/poh.out")" "1"
check "and does not say 'the client' (it names the build it measured)" "$(grep -c 'the client' "$WORK/poh.out")" "0"
check "the other keys of that conf are applied" "${SSH_PORT:-x}" "2222"
unset SSH_PORT
# through config_import (the path of `import` and of `install --config`): the rest imports, poh_core is not recorded
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; seed_state; config_export >/dev/null 2>&1
printf 'POH_CORE="10"\n' >>"$CONFIG_FILE"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
RESCORE=0 config_import >"$WORK/oldimp.out" 2>&1; IRC=$?
check "an old exported conf imports (rc 0), with one warning" "$IRC|$(grep -c 'POH_CORE is ignored' "$WORK/oldimp.out")" "0|1"
check "  nothing recorded as poh_core, the rest imported"    "$(state_get poh_core '<none>')|$(state_get xdp_cores)|$(state_get vote_account_pubkey)" "<none>|1-2|$VOTE"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; seed_state; config_export >/dev/null 2>&1   # the clean conf again

echo "== P2: empty value SKIPPED (preserves default), export omits empties =="
DZ_ENV="mainnet-beta"                                   # a default already in the global
printf 'DZ_ENV=""\n' > "$WORK/e.conf"
_config_parse_safe "$WORK/e.conf" >/dev/null 2>&1
check "DZ_ENV='' does NOT clobber default"     "$DZ_ENV" "mainnet-beta"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; seed_state
state_clear dz_env
CONFIG_FILE="$WORK/p2.conf" config_export >/dev/null 2>&1
check "empty dz_env -> NO DZ_ENV= line"        "$(grep -c '^DZ_ENV=' "$WORK/p2.conf")" "0"
check "non-empty key still emitted"            "$(grep -c '^SSH_PORT=' "$WORK/p2.conf")" "1"

echo "== P11: NODE_NAME fully removed (export emits none; not whitelisted) =="
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; seed_state
CONFIG_FILE="$WORK/p11.conf" config_export >/dev/null 2>&1
check "export has NO NODE_NAME line"           "$(grep -c 'NODE_NAME' "$WORK/p11.conf")" "0"
check "NODE_NAME not a whitelisted type"       "$(_config_key_type NODE_NAME)" ""

echo "== METRICS_TARGET: exported, imported, typed mainnet-beta|bam =="
# The metrics choice used to be env-only, so an exported conf could not carry it.
seed_state; state_set metrics_target bam
CONFIG_FILE="$WORK/metrics.conf" config_export >/dev/null 2>&1
check "export carries METRICS_TARGET"          "$(grep -c '^METRICS_TARGET="bam"$' "$WORK/metrics.conf")" "1"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( CONFIG_FILE="$WORK/metrics.conf" RESCORE=0 config_import ) >/dev/null 2>&1
check "import restores it to state"            "$(state_get metrics_target '<none>')" "bam"
check "type: mainnet-beta"                     "$(_cfg_validate_type metrics mainnet-beta && echo ok || echo refused)" "ok"
check "type: bam"                              "$(_cfg_validate_type metrics bam && echo ok || echo refused)" "ok"
check "type: anything else is refused"         "$(_cfg_validate_type metrics influx && echo ok || echo refused)" "refused"

echo "== Fix1: deeploy.conf.example parses with EVERY key valid =="
EX="$ROOT/deeploy.conf.example"
check_true "example file exists"               "[[ -f \"$EX\" ]]"
_config_parse_safe "$EX" >/dev/null 2>&1; rc=$?
check "example: all keys validate (rc 0)"      "$rc" "0"
check "example: SSH_PORT parsed, comment ignored"  "$SSH_PORT" "22"
check "example: SHRED hostport parsed"             "$SHRED_RECEIVER_ADDRESS" "203.0.113.7:1002"
check "example: MEV_MODE parsed"                   "$MEV_MODE" "bam"
check "example: METRICS_TARGET parsed"             "${METRICS_TARGET:-<unset>}" "mainnet-beta"
# Not pinned to a literal tag (that pin drifted every bump and the test just
# followed). The example tag parses, clears our floor, and maps to an Anza
# release name by the code phase 4 uses; whether that release exists is not
# checked here.
check "example: JITO_TAG parsed"                   "$(deeploy_tag_version "$JITO_TAG" >/dev/null && echo parses || echo NO)" "parses"
check_true "example: JITO_TAG meets our own floor" "deeploy_tag_floor_problem \"\$JITO_TAG\" >/dev/null"
# and the recommendation; without the constant (the old tree) the floor is set
# out of reach, so this fails instead of set -u killing the file
check_true "example: JITO_TAG meets the recommendation" "deeploy_tag_floor_problem \"\$JITO_TAG\" \"\${DEEPLOY_RECOMMENDED_JITO_TAG:-v999.0.0-jito}\" >/dev/null"
check "example: JITO_TAG is the shipped pin"       "$JITO_TAG" "${DEEPLOY_PIN_JITO_TAG:-<no pin>}"
check "example: the comment names the recommendation" "$(grep -cF "RECOMMENDED: ${DEEPLOY_RECOMMENDED_JITO_TAG:-?} or newer" "$EX")" "1"
check "example: the comment says the 4.4.0 alpha, beta and rc.0 tags get no warning" "$(grep -cF 'the 4.4.0 alpha, beta and rc.0 tags get none' "$EX")" "1"
check "example: JITO_TAG matches the file"         "$JITO_TAG" "$(sed -n 's/^JITO_TAG="\([^"]*\)".*/\1/p' "$EX")"
# Phase 4's own toolchain_anza_cli, dry-run, on the tag the parser just read. The
# expected name is derived here, independently: the tag with -jito[.N] cut off.
EXTAG="$JITO_TAG"
EXANZA=$( (
    # shellcheck source-path=SCRIPTDIR source=../lib/toolchain.sh
    source "$ROOT/lib/toolchain.sh"
    DRY_RUN=1 JITO_TAG="$EXTAG" toolchain_anza_cli
) 2>&1 )
check "example: phase 4 names Anza release ${EXTAG%-jito*}" "$(lines_with 'install scaffold' "$EXANZA")" "━━━ anza CLI ${EXTAG%-jito*} (PATH + install scaffold) ━━━"

echo "== X6: _config_keys <-> _config_key_type are in lockstep =="
sync_missing=0
while read -r a b; do
    [[ -z "$a" || "$a" == "@" ]] && continue
    [[ -n "$(_config_key_type "$a")" ]] || { echo "  MISSING TYPE: $a"; sync_missing=1; }
done < <(_config_keys)
check "every _config_keys key has a type"      "$sync_missing" "0"
keys_set="$(_config_keys     | awk '$1!="@"{print $1}' | sort)"
types_set="$(_config_key_types | awk '{print $1}'      | sort)"
check "typed-key set == _config_keys key set"  "$types_set" "$keys_set"

echo "== MAX_LOCAL_SNAPSHOT_AGE: a conf key (int), exported and imported =="
# It used to be a literal in validator.sh, so a re-render dropped a hand edit.
check "typed int"                              "$(_config_key_type MAX_LOCAL_SNAPSHOT_AGE)" "int"
seed_state; state_set max_local_snapshot_age 20480
CONFIG_FILE="$WORK/age.conf" config_export >/dev/null 2>&1
check "export carries it"                      "$(grep -c '^MAX_LOCAL_SNAPSHOT_AGE="20480"$' "$WORK/age.conf")" "1"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( CONFIG_FILE="$WORK/age.conf" RESCORE=0 config_import ) >/dev/null 2>&1
check "import restores it to state"            "$(state_get max_local_snapshot_age '<none>')" "20480"

echo "== R10-6: offbox round-trips — mode + pubkey out, no staked path, back in =="
seed_state
state_clear staked_keypair                       # offbox keeps no staked path
state_set staked_key_mode offbox; state_set staked_pubkey kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu
config_export >/dev/null 2>&1
check "offbox export: mode"                  "$(grep -c '^STAKED_KEY_MODE="offbox"$' "$CONFIG_FILE")" "1"
check "offbox export: staked pubkey"         "$(grep -c '^STAKED_PUBKEY="kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu"$' "$CONFIG_FILE")" "1"
check "offbox export: no STAKED_KEYPAIR"     "$(grep -c '^STAKED_KEYPAIR=' "$CONFIG_FILE")" "0"
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
unset STAKED_KEY_MODE STAKED_PUBKEY STAKED_KEYPAIR
RESCORE=0 config_import >/dev/null 2>&1
check "offbox import: mode + pubkey back in state" "$(state_get staked_key_mode)|$(state_get staked_pubkey)" "offbox|kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu"
check "offbox import: no staked path appears"      "$(state_get staked_keypair '<unset>')" "<unset>"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
