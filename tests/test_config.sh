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
# shellcheck source-path=SCRIPTDIR source=../lib/config.sh
source "$ROOT/lib/config.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

DRY_RUN=0 common_init
VOTE="Vote1111111111111111111111111111111111111111"

seed_state() {
    rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
    state_set node_name MYBOX;            state_set ssh_port 2222
    state_set poh_core 10;                state_set xdp_cores_count 2; state_set xdp_cores 1-2
    state_set isolated_set "1-2,10,25-26,34"
    state_set nic_driver mlx5_core;       state_set retransmit_supported 1; state_set retransmit_zero_copy 1
    state_set disk_layout two-nvme;       state_set ledger_disk /dev/nvme0n1; state_set accounts_disk /dev/nvme1n1
    state_set solana_home /root/solana;   state_set ledger_path /root/solana/ledger
    state_set accounts_path /mnt/accounts/solana/accounts; state_set snapshots_path /root/solana/snapshots
    state_set jito_tag v4.0.0-jito
    state_set fake_identity /root/solana/mvkfake/mainnet-validator-keypair.json
    state_set unstaked_keypair /root/solana/unstaked-identity.json
    state_set staked_keypair /root/solana/mainnet-validator-keypair.json
    state_set vote_account_pubkey "$VOTE"
    state_set mev_mode bam; state_set bam_url http://slc.mainnet.bam.jito.wtf
    state_set block_engine_url https://slc.mainnet.block-engine.jito.wtf
    state_set shred_receiver 64.130.53.8:1002; state_set commission_bps 0
    state_set dz_enabled true; state_set dz_env mainnet-beta; state_set dz_multicast true
    state_set dz_client_ip 203.0.113.7; state_set dz_keypair /root/solana/dz-keypair.json
}

echo "== export: content, no key material, chmod 600 =="
seed_state
config_export >/dev/null 2>&1
check_true "conf written"           "[[ -f \"$CONFIG_FILE\" ]]"
check "SSH_PORT"                    "$(grep -c 'SSH_PORT=\"2222\"' "$CONFIG_FILE")" "1"
check "POH_CORE"                    "$(grep -c 'POH_CORE=\"10\"' "$CONFIG_FILE")" "1"
check "JITO_TAG"                    "$(grep -c 'JITO_TAG=\"v4.0.0-jito\"' "$CONFIG_FILE")" "1"
check "STAKED_KEYPAIR is a PATH"    "$(grep -c 'STAKED_KEYPAIR=\"/root/solana/mainnet-validator-keypair.json\"' "$CONFIG_FILE")" "1"
check "VOTE pubkey (public)"        "$(grep -c "VOTE_ACCOUNT_PUBKEY=\"$VOTE\"" "$CONFIG_FILE")" "1"
check "BAM/region captured"         "$(grep -c 'BAM_URL=\"http://slc.mainnet.bam.jito.wtf\"' "$CONFIG_FILE")" "1"
check "NO key material (JSON array)" "$(grep -cE '\[[0-9]+,[0-9]+' "$CONFIG_FILE")" "0"
check "NO .json contents leaked"    "$(grep -cE '^\[|,[0-9]+,[0-9]+,' "$CONFIG_FILE")" "0"
# shellcheck disable=SC2012  # ls is fine here; portable perm read for the test
check "chmod 600"                   "$(ls -l "$CONFIG_FILE" | cut -c1-10)" "-rw-------"

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
check "imported poh_core"   "$(state_get poh_core)" "10"
check "imported vote"       "$(state_get vote_account_pubkey)" "$VOTE"
check "imported staked path" "$(state_get staked_keypair)" "/root/solana/mainnet-validator-keypair.json"
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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
