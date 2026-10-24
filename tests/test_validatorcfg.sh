#!/usr/bin/env bash
# Self-contained tests for lib/validatorcfg.sh — no root, no systemd. Renders to
# strings/temp files and asserts every arg block, the RETRANSMIT/DZ/commission
# conditionals, and the generated validator.sh passing bash -n.
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
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# base.sh / keys.sh / config.sh provide the typed validators reused by the X1
# render gate (_cfg_validate_type); production sources all modules, mirror that.
# shellcheck source-path=SCRIPTDIR source=../lib/base.sh
source "$ROOT/lib/base.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/keys.sh
source "$ROOT/lib/keys.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/validatorcfg.sh
source "$ROOT/lib/validatorcfg.sh"

PASS=0; FAIL=0
check()      { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

DRY_RUN=0 common_init
systemctl() { :; }; ln() { :; }

seed() {
    state_set jito_tag v4.2.1-jito          # a box that has built a supported client
    state_set solana_home /root/solana
    state_set sync_identity /root/solana/unstaked-identity.json
    state_set vote_account_pubkey Vote1111111111111111111111111111111111111111
    state_set ledger_path /root/solana/ledger
    state_set accounts_path /mnt/accounts/solana/accounts
    state_set snapshots_path /root/solana/snapshots
    state_set disk_layout two-nvme
    state_set suggested_bam_url http://amsterdam.mainnet.bam.jito.wtf
    state_set suggested_block_engine_url https://amsterdam.mainnet.block-engine.jito.wtf
    state_set suggested_shred_receiver 74.118.140.240:1002
}
seed

echo "== validator.sh: arg blocks (BAM, no retransmit, no DZ) =="
state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
MEV_MODE=bam; state_set dz_enabled false; validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "identity = sync identity" "$(grep -c -- '--identity "/root/solana/unstaked-identity.json"' <<<"$V")" "1"
check "vote-account"           "$(grep -c -- '--vote-account "Vote1111' <<<"$V")" "1"
check "genesis hash"           "$(grep -c -- "--expected-genesis-hash \"$MAINNET_GENESIS_HASH\"" <<<"$V")" "1"
check "5 entrypoints"          "$(grep -c -- '--entrypoint "entrypoint' <<<"$V")" "5"
check "4 known-validators"     "$(grep -c -- '--known-validator' <<<"$V")" "4"
check "no blank before ) after known" "$(awk '/--known-validator "CakcnaRD/{getline; print}' <<<"$V")" ")"
check "private-rpc + bind 127" "$(grep -c -- '--rpc-bind-address "127.0.0.1"' <<<"$V")" "1"
check "no --poh-pinned-cpu-core: there is no PoH thread to pin" "$(grep -c -- 'poh-pinned-cpu-core' <<<"$V")" "0"
check "no POH block, defined or run"           "$(grep -c 'POH' <<<"$V")" "0"
check "--no-poh-speed-test stays (a speed-test flag, not a pin)" "$(grep -c -- '--no-poh-speed-test' <<<"$V")" "1"
check "unified-scheduler 14"   "$(grep -c -- '--unified-scheduler-handler-threads "14"' <<<"$V")" "1"
check "ledger path"            "$(grep -c -- '--ledger "/root/solana/ledger"' <<<"$V")" "1"
check "accounts on accounts disk" "$(grep -c -- '--accounts "/mnt/accounts/solana/accounts"' <<<"$V")" "1"
check "snapshots on ledger disk"  "$(grep -c -- '--snapshots "/root/solana/snapshots"' <<<"$V")" "1"
check "account-index program-id"  "$(grep -c -- '--account-index program-id' <<<"$V")" "1"
check "account-index ALT key"     "$(grep -c -- "--account-index-include-key \"$ALT_PROGRAM_KEY\"" <<<"$V")" "1"
check "tip-payment program"    "$(grep -c -- "--tip-payment-program-pubkey \"$JITO_TIP_PAYMENT_PROGRAM\"" <<<"$V")" "1"
check "merkle authority"       "$(grep -c -- "--merkle-root-upload-authority \"$JITO_MERKLE_ROOT_AUTHORITY\"" <<<"$V")" "1"
check "bam-url present"        "$(grep -c -- '--bam-url "http://amsterdam.mainnet.bam.jito.wtf"' <<<"$V")" "1"
check "commission-bps 0 (bam)" "$(grep -c -- '--commission-bps "0"' <<<"$V")" "1"
check "RETRANSMIT block present anyway (states the choice)" "$(grep -c 'RETRANSMIT=(' <<<"$V")" "1"
check "unsupported NIC -> explicit --no-xdp"  "$(grep -c -- '--no-xdp' <<<"$V")" "1"
check "shred single address"   "$(grep -c -- '--shred-receiver-address "74.118.140.240:1002"$' <<<"$V")" "1"
check "every interpolated value is double-quoted (no bare --ledger)" "$(grep -c -- '--ledger /' <<<"$V")" "0"

echo "== --maximum-local-snapshot-age: a knob, one constant by default, above the incremental interval =="
# It was a hardcoded 4000, below the 5120-slot incremental interval: on
# 2026-10-13 the start check found the cluster's next incremental 4882 slots
# ahead, refused the local snapshot as too old, and the fetch that followed looped.
# ${…:-}: without the constant (the old tree) these fail instead of set -u
# killing the file.
check "default age = DEFAULT_MAX_LOCAL_SNAPSHOT_AGE" "$(grep -c -- "--maximum-local-snapshot-age \"${DEFAULT_MAX_LOCAL_SNAPSHOT_AGE:-<no default>}\"" <<<"$V")" "1"
check_true "  which is above the default incremental interval (5120)" "(( ${DEFAULT_MAX_LOCAL_SNAPSHOT_AGE:-0} > 5120 ))"
SA=$( ( MAX_LOCAL_SNAPSHOT_AGE=200000; MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1; _vcfg_render_validator_sh ) 2>/dev/null )
check "MAX_LOCAL_SNAPSHOT_AGE=200000 -> rendered" "$(grep -c -- '--maximum-local-snapshot-age "200000"' <<<"$SA")" "1"
SAOUT=$( ( MAX_LOCAL_SNAPSHOT_AGE=4000; INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS=5120; MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 ); SARC=$?
check "age 4000 at incremental 5120 -> refused"  "$SARC" "1"
check "  the refusal names both numbers"          "$(grep -c 'MAX_LOCAL_SNAPSHOT_AGE (4000) must exceed INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS (5120)' <<<"$SAOUT")" "1"
( MAX_LOCAL_SNAPSHOT_AGE=5120; INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS=5120; MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "age equal to the interval -> refused"     "$?" "1"
( MAX_LOCAL_SNAPSHOT_AGE=5121; INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS=5120; MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "age one above the interval -> ok"         "$?" "0"
( MAX_LOCAL_SNAPSHOT_AGE=lots; MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1; _vcfg_render_validator_sh ) >/dev/null 2>&1
check "a non-number age -> the render refuses"   "$?" "1"

echo "== N4: generated header advertises a RUNNABLE regenerate hint (rendered, not template) =="
check "header: runnable numeric form via DEEPLOY_CMD" "$(grep -c -- 'regenerate via: ./deeploy.sh install --only 6' <<<"$V")" "1"
check "header: NOT the broken '--only validatorcfg'"  "$(grep -c -- '--only validatorcfg' <<<"$V")" "0"

echo "== OS stats: the validator reports them with its metrics =="
# A REPORTING block of four --no-os-*-stats-reporting flags turned them off.
check "no --no-os-*-stats-reporting flag"  "$(grep -c -- '--no-os-' <<<"$V")" "0"
check "no REPORTING block, defined or run" "$(grep -c 'REPORTING' <<<"$V")" "0"
# control: every other block is still defined and run, in the same order
for b in CONSENSUS GOSSIP RPC REPLAY RETRANSMIT LEDGER SNAPSHOTS LOG JITO; do
    check "block $b defined and run" "$(grep -c "^${b}=(" <<<"$V")|$(grep -cF "\"\${${b}[@]}\"" <<<"$V")" "1|1"
done
# SC2016: the literal ${NAME[@]} of the generated script is what is matched.
# shellcheck disable=SC2016
check "blocks run in order" "$(grep -o '\${[A-Z]*\[@\]}' <<<"$V" | sed 's/^\${\([A-Z]*\)\[@\]}$/\1/' | tr '\n' ' ')" \
      "CONSENSUS GOSSIP RPC REPLAY RETRANSMIT LEDGER SNAPSHOTS LOG JITO "

echo "== RETRANSMIT: mlx5 = cpu-cores + zero-copy, in order =="
state_set retransmit_supported 1; state_set retransmit_zero_copy 1; state_set xdp_cores 1-2
validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "cpu-cores 1-2 present"        "$(grep -c -- '--xdp-cpu-cores "1-2"' <<<"$V")" "1"
check "zero-copy present (mlx5)"     "$(grep -c -- '--xdp-zero-copy' <<<"$V")" "1"
check "XDP enabled -> NO --no-xdp"   "$(grep -c -- '--no-xdp' <<<"$V")" "0"
check "cpu-cores BEFORE zero-copy"   "$(awk '/xdp-cpu-cores/{c=NR} /xdp-zero-copy/{z=NR} END{print (c<z)?"yes":"no"}' <<<"$V")" "yes"
check "RETRANSMIT in exec list"      "$(grep -c 'RETRANSMIT\[@\]' <<<"$V")" "1"

echo "== RETRANSMIT: bnxt = cpu-cores, NO zero-copy =="
state_set retransmit_supported 1; state_set retransmit_zero_copy 0; state_set xdp_cores 1-2
validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "bnxt cpu-cores present"  "$(grep -c -- '--xdp-cpu-cores "1-2"' <<<"$V")" "1"
check "bnxt zero-copy ABSENT"   "$(grep -c -- '--xdp-zero-copy' <<<"$V")" "0"
check "bnxt: NO --no-xdp"       "$(grep -c -- '--no-xdp' <<<"$V")" "0"

echo "== 4.2 opt-out inversion: the render ALWAYS states the XDP choice =="
# Agave 4.2.0 flipped XDP from opt-in to opt-out: emitting no flags now means
# ENABLED (auto interface, auto core). Both paths that decide against XDP must
# therefore say --no-xdp out loud.
state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "unsupported NIC -> --no-xdp"          "$(grep -c -- '--no-xdp' <<<"$V")" "1"
check "unsupported NIC -> no xdp-cpu-cores"  "$(grep -c -- '--xdp-cpu-cores' <<<"$V")" "0"
check "RETRANSMIT still in the exec list"    "$(grep -c 'RETRANSMIT\[@\]' <<<"$V")" "1"
# the SECOND silent path: eligible NIC, but the operator reserved no cores in
# phase 2 — include_retransmit=0 with RETRANSMIT_SUPPORTED=1
state_set retransmit_supported 1; state_set retransmit_zero_copy 1; state_set xdp_cores ""
validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "eligible NIC + no cores -> --no-xdp"  "$(grep -c -- '--no-xdp' <<<"$V")" "1"
check "eligible NIC + no cores -> no cores flag" "$(grep -c -- '--xdp-cpu-cores' <<<"$V")" "0"
check "eligible NIC + no cores -> no zero-copy"  "$(grep -c -- '--xdp-zero-copy' <<<"$V")" "0"
# and the retired names appear NOWHERE, in any configuration
check "no deprecated experimental-* names"   "$(grep -c 'experimental-' <<<"$V")" "0"
# the RETRANSMIT block is now unconditional, so BOTH shapes must still parse
printf '%s' "$V" >"$WORK/vsh_noxdp.sh"
check_true "generated validator.sh (--no-xdp) passes bash -n" "bash -n \"$WORK/vsh_noxdp.sh\""
state_set retransmit_supported 1; state_set retransmit_zero_copy 1; state_set xdp_cores 1-2
validatorcfg_resolve_config
_vcfg_render_validator_sh >"$WORK/vsh_xdp.sh"
check_true "generated validator.sh (xdp on) passes bash -n"   "bash -n \"$WORK/vsh_xdp.sh\""
check "xdp-on shape has cores + zero-copy"   "$(grep -cE -- '--xdp-(cpu-cores|zero-copy)' "$WORK/vsh_xdp.sh")" "2"

echo "== validator.sh: 2nd shred address GATED on dz_enabled (the single DZ decision) =="
state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
# dz_should_enable isn't sourced here (validatorcfg-only test) -> resolve falls back
# to state_get dz_enabled. dz_enabled=true -> both shred addresses.
state_set dz_enabled true; unset DZ_ENABLED DZ_MULTICAST; validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "dz_enabled=true: BOTH shred addrs (jito + DZ multicast)" "$(grep -c -- "--shred-receiver-address \"74.118.140.240:1002\" \"$DZ_MULTICAST_SHRED\"" <<<"$V")" "1"
# dz_enabled=false -> ONLY the Jito primary, no DZ multicast address.
state_set dz_enabled false; validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "dz_enabled=false: only Jito primary"  "$(grep -c -- "--shred-receiver-address \"74.118.140.240:1002\"\$" <<<"$V")" "1"
check "dz_enabled=false: NO DZ multicast addr" "$(grep -c -- "$DZ_MULTICAST_SHRED" <<<"$V")" "0"

echo "== validator.sh: relayer mode flips url + commission =="
MEV_MODE=relayer; state_set dz_enabled false; unset COMMISSION_BPS; validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh)
check "relayer-url present"     "$(grep -c -- '--relayer-url ' <<<"$V")" "1"
check "bam-url absent"          "$(grep -c -- '--bam-url' <<<"$V")" "0"
check "commission-bps 1000"     "$(grep -c -- '--commission-bps "1000"' <<<"$V")" "1"
# commission is prompted with a mode default but an explicit value is kept (not forced)
COMMISSION_BPS=700; MEV_MODE=bam; validatorcfg_resolve_config
check "explicit commission 700 kept" "$COMMISSION_BPS" "700"
unset COMMISSION_BPS

echo "== N9: COMMISSION_BPS bounded 0-10000 — at prompt, env, and the render gate =="
seed; state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
state_set dz_enabled false
( COMMISSION_BPS=20000 MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N9: env 20000 -> resolve fails"    "$?" "1"
( COMMISSION_BPS=1e9 MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N9: junk '1e9' -> resolve fails"   "$?" "1"
( COMMISSION_BPS=10000 MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N9: boundary 10000 accepted"       "$?" "0"
( COMMISSION_BPS=0 MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N9: boundary 0 accepted"           "$?" "0"
# the PROMPT path is validated too (operator typo at the ask)
ask() { REPLY=99999; }
( unset COMMISSION_BPS; NONINTERACTIVE=0 MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N9: prompted 99999 -> fails"       "$?" "1"
unset -f ask
# render gate: a hostile value seeded straight into the global after resolve
unset COMMISSION_BPS; MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1
COMMISSION_BPS=10001
N9V=$(_vcfg_render_validator_sh 2>/dev/null); N9RC=$?
check_true "N9: render gate refuses 10001 (rc!=0, no script)" "[[ \"$N9RC\" != \"0\" && -z \"$N9V\" ]]"
unset COMMISSION_BPS

echo "== N16: SOLANA_METRICS_CONFIG (env-only) gated before any render =="
seed
( SOLANA_METRICS_CONFIG='host=x;touch /tmp/pwn' MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N16: ';' refused"                  "$?" "1"
# SC2016: literal $(...) payload on purpose.
# shellcheck disable=SC2016
( SOLANA_METRICS_CONFIG='host=x"$(id)"' MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N16: quote+\$ refused"             "$?" "1"
rm -f "$WORK/n16.sh"
# SC2030/SC2031: the VALIDATOR_SH override is deliberately subshell-local.
# shellcheck disable=SC2030,SC2031
( export VALIDATOR_SH="$WORK/n16.sh" SOLANA_METRICS_CONFIG='a;b' MEV_MODE=bam
  validatorcfg_resolve_config && validatorcfg_generate ) >/dev/null 2>&1
check "N16: hostile metrics -> no artifact written" "$([[ -e "$WORK/n16.sh" ]] && echo y || echo n)" "n"
( MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "N16: shipped default (commas + =) passes"    "$?" "0"
MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1   # restore clean globals

echo "== R3: empty MEV endpoints FAIL resolve (no valueless flags rendered) =="
# A failed region scan + no override leaves BAM/BLOCK_ENGINE/SHRED empty; the
# renderer would emit bare flags (argv misalignment) -> unattended Phase 8
# crash-loop. resolve must fail fast instead.
state_clear suggested_bam_url; state_clear suggested_block_engine_url; state_clear suggested_shred_receiver
( unset BAM_URL BLOCK_ENGINE_URL SHRED_RECEIVER_ADDRESS; MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "R3: bam mode + empty MEV urls -> resolve fails"       "$?" "1"
( unset BLOCK_ENGINE_URL SHRED_RECEIVER_ADDRESS; MEV_MODE=relayer validatorcfg_resolve_config ) >/dev/null 2>&1
check "R3: relayer mode + empty block-engine/shred -> fails" "$?" "1"
seed; unset BAM_URL BLOCK_ENGINE_URL SHRED_RECEIVER_ADDRESS RELAYER_URL   # restore for later tests
MEV_MODE=bam validatorcfg_resolve_config

echo "== solana.service =="
MEV_MODE=bam; validatorcfg_resolve_config
S=$(_vcfg_render_solana_service)
check "5 ambient caps"          "$(grep -c 'AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SYS_NICE' <<<"$S")" "1"
check "Nice=-10"                "$(grep -c 'Nice=-10' <<<"$S")" "1"
check "OOMScoreAdjust=-1000"    "$(grep -c 'OOMScoreAdjust=-1000' <<<"$S")" "1"
check "LimitNOFILE 2000000"     "$(grep -c 'LimitNOFILE=2000000' <<<"$S")" "1"
check "R10-10: LimitCORE=0 (no core dumps)"              "$(grep -c '^LimitCORE=0$' <<<"$S")" "1"
check "R10-10: CoredumpFilter=elf-headers (no heap/stack)" "$(grep -c '^CoredumpFilter=elf-headers$' <<<"$S")" "1"
check "no ExecStartPost for the poh-pin service"  "$(grep -c 'poh-pin' <<<"$S")" "0"
check "no ExecStartPost at all"                    "$(grep -c 'ExecStartPost' <<<"$S")" "0"
check "metrics = mainnet-beta" "$(grep -c '^Environment="SOLANA_METRICS_CONFIG=host=https://metrics.solana.com:8086,db=mainnet-beta,' <<<"$S")" "1"
check "metrics: not the BAM endpoint"          "$(grep -c 'bam-public-metrics.jito.wtf' <<<"$S")" "0"
check "RequiresMountsFor (two-nvme)" "$(grep -c 'RequiresMountsFor=/mnt/accounts /mnt/ledger' <<<"$S")" "1"
check "ExecStart = validator.sh" "$(grep -c 'ExecStart=/root/solana/validator.sh' <<<"$S")" "1"
check "R4: StartLimitIntervalSec=0 (rate limiter disabled)" "$(grep -c '^StartLimitIntervalSec=0' <<<"$S")" "1"
check "R4: NOT the permanent-down =5"                        "$(grep -c 'StartLimitIntervalSec=5' <<<"$S")" "0"
# RequiresMountsFor must be ABSENT on root layout (no separate mounts to wait on).
state_set disk_layout root; validatorcfg_resolve_config
check "no RequiresMountsFor on root layout" "$(grep -c 'RequiresMountsFor' "$(_vcfg_render_solana_service >"$WORK/sv"; echo "$WORK/sv")")" "0"
state_set disk_layout two-nvme

echo "== metrics: mainnet-beta unless BAM is chosen; the choice is recorded =="
# SFDP's metric-reporting check used to read optimistic_slot.slot from the
# mainnet-beta database; a box reporting to the BAM endpoint had passed:false there
# (epochs 1055-1061). Under Alpenglow the validator does not send that metric any
# more (see the next block), so mainnet-beta stays the default on the strength of
# Anza's cluster docs and Jito's BAM guide, which docs/INSTALL.md names.
state_clear metrics_target
SVC=$( ( unset METRICS_TARGET SOLANA_METRICS_CONFIG; MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1; _vcfg_render_solana_service ) )
check "default -> metrics.solana.com"          "$(grep -c 'host=https://metrics.solana.com:8086,db=mainnet-beta,' <<<"$SVC")" "1"
check "default recorded"                       "$(state_get metrics_target '<none>')" "mainnet-beta"
SVC=$( ( unset SOLANA_METRICS_CONFIG; METRICS_TARGET=bam MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1; _vcfg_render_solana_service ) )
check "METRICS_TARGET=bam -> the BAM endpoint" "$(grep -c 'host=http://bam-public-metrics.jito.wtf:8086,db=mainnet-bam-validators,' <<<"$SVC")" "1"
check "  and not mainnet-beta"                 "$(grep -c 'metrics.solana.com' <<<"$SVC")" "0"
check "bam recorded"                           "$(state_get metrics_target '<none>')" "bam"
SVC=$( ( unset METRICS_TARGET SOLANA_METRICS_CONFIG; MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1; _vcfg_render_solana_service ) )
check "a re-render with nothing set keeps the recorded bam" "$(grep -c 'bam-public-metrics.jito.wtf' <<<"$SVC")" "1"
( unset SOLANA_METRICS_CONFIG; METRICS_TARGET=influx MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "METRICS_TARGET=influx -> refused"       "$?" "1"
SVC=$( ( METRICS_TARGET=bam SOLANA_METRICS_CONFIG='host=https://example.org:8086,db=x,u=y,p=z' MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1
         _vcfg_render_solana_service ) )
check "env SOLANA_METRICS_CONFIG overrides the target" "$(grep -c '^Environment="SOLANA_METRICS_CONFIG=host=https://example.org:8086,db=x,u=y,p=z"$' <<<"$SVC")" "1"
# Two resolves in one process: the first one's result is not taken for an override.
SVC=$( ( unset METRICS_TARGET SOLANA_METRICS_CONFIG; state_clear metrics_target
         MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1
         METRICS_TARGET=bam MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1
         _vcfg_render_solana_service ) )
check "a second resolve follows its own target" "$(grep -c 'bam-public-metrics.jito.wtf' <<<"$SVC")" "1"
state_clear metrics_target
MEV_MODE=bam validatorcfg_resolve_config >/dev/null 2>&1   # restore clean globals

echo "== metrics: the docs do not claim that SFDP reads optimistic_slot today =="
# Under Alpenglow the validator no longer sends optimistic_slot (jito-solana v4.3.2-jito: the datapoint has one
# source, core/src/optimistic_confirmation_verifier.rs 80, and core/src/cluster_info_vote_listener.rs 657-660
# drops that verifier); SFDP's API, read 2026-10-22, lists metric-reporting-ignored for epochs 1062 and 1063.
# So the default stays mainnet-beta on Anza's and Jito's word, and the check on optimistic_slot is history.
MET=$(awk '/^## Metrics$/ {on = 1; next} /^## / {on = 0} on' "$ROOT/docs/INSTALL.md")
# shellcheck disable=SC2016    # the backticks are markdown
check "INSTALL Metrics: the default host and its two sources stay" \
      "$(grep -c 'mainnet-beta (`metrics.solana.com`) by default' <<<"$MET")|$(grep -c 'docs.anza.xyz/clusters/available' <<<"$MET")|$(grep -c 'bam.dev/validators' <<<"$MET")" "1|1|1"
check "INSTALL Metrics: optimistic_slot is history, with what SFDP's API showed and when" \
      "$(grep -c 'check used to read one core metric' <<<"$MET")|$(grep -c 'no longer sends it' <<<"$MET")|$(grep -c 'metric-reporting-ignored' <<<"$MET")|$(grep -c '2026-10-22' <<<"$MET")" "1|1|1|1"
check "INSTALL Metrics: no claim that the destination decides SFDP's check" "$(grep -c 'do not count for it' <<<"$MET")|$(grep -c 'reads one core metric' <<<"$MET")" "0|0"
check "no present-tense claim that SFDP reads optimistic_slot, in lib, docs, README or the example conf" \
      "$(grep -rnF -e 'reads one core metric' -e "metric check reads it" -e 'do not count for it' "$ROOT/lib" "$ROOT/docs" "$ROOT/README.md" "$ROOT/deeploy.conf.example" | grep -c .)" "0"

echo "== H1: solana.service installs as a REAL file under /etc, not on a data mount =="
# systemd loads enabled units at early boot, before local-fs mounts; an on-mount
# unit ($SOLANA_HOME -> ledger symlink) is unreadable then and dropped from the
# boot transaction. The default install path must be /etc/systemd/system.
# stderr apart: the suite's tag (v4.2.1-jito) is below the recommendation, and
# the render warns about it there.
( unset SOLANA_SERVICE; state_set solana_home /root/solana; validatorcfg_resolve_config
  echo "$SOLANA_SERVICE" ) >"$WORK/svpath" 2>"$WORK/svpath.err"
check "H1: unit path is /etc/systemd/system (root fs)"  "$(cat "$WORK/svpath")" "/etc/systemd/system/solana.service"
check "H1: unit NOT under SOLANA_HOME (the ledger mount)" "$(grep -c '/root/solana/solana.service' "$WORK/svpath")" "0"
validatorcfg_resolve_config

echo "== validator.sh paths read from STATE (not hardcoded /mnt) =="
state_set ledger_path /custom/led; state_set accounts_path /custom/acc; state_set snapshots_path /custom/snap
validatorcfg_resolve_config; V=$(_vcfg_render_validator_sh)
check "ledger from state"    "$(grep -c -- '--ledger "/custom/led"' <<<"$V")" "1"
check "accounts from state"  "$(grep -c -- '--accounts "/custom/acc"' <<<"$V")" "1"
check "snapshots from state" "$(grep -c -- '--snapshots "/custom/snap"' <<<"$V")" "1"
state_set ledger_path /root/solana/ledger; state_set accounts_path /mnt/accounts/solana/accounts; state_set snapshots_path /root/solana/snapshots
validatorcfg_resolve_config

echo "== X1: a hostile value seeded DIRECTLY to state -> render is fail-closed =="
# Bypass the config parser (write straight to state) with a value crafted to break
# out of the validator.sh heredoc. The render-gate (_cfg_validate_type path) must
# refuse, render must produce nothing, and nothing must execute.
seed; state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
MEV_MODE=bam; state_set dz_enabled false
state_set ledger_path '/x")</dev/null;touch '"$WORK"'/pwned #'
validatorcfg_resolve_config
rm -f "$WORK/pwned"
V=$(_vcfg_render_validator_sh); rc=$?
check_true "X1: render ABORTS on hostile LEDGER_PATH (rc != 0)" "[[ \"$rc\" != \"0\" ]]"
check_true "X1: render produced NO script"                     "[[ -z \"$V\" ]]"
check_true "X1: nothing executed (no sentinel)"                "[[ ! -e \"$WORK/pwned\" ]]"
# pubkey gate too: a hostile vote pubkey is rejected at the render point.
state_set ledger_path /root/solana/ledger
# SC2016: the $(...) is a LITERAL hostile payload, kept unexpanded on purpose.
# shellcheck disable=SC2016
state_set vote_account_pubkey 'Vote111 $(touch '"$WORK"'/pwned)'
validatorcfg_resolve_config
rm -f "$WORK/pwned"
V=$(_vcfg_render_validator_sh); rc=$?
check_true "X1: render ABORTS on hostile VOTE pubkey (rc != 0)" "[[ \"$rc\" != \"0\" ]]"
check_true "X1: hostile vote — no sentinel"                     "[[ ! -e \"$WORK/pwned\" ]]"
# Restore a clean baseline; the gate now passes and quoting is present.
seed; state_set retransmit_supported 0; state_set retransmit_zero_copy 0; state_set xdp_cores ""
MEV_MODE=bam; state_set dz_enabled false; validatorcfg_resolve_config
V=$(_vcfg_render_validator_sh); rc=$?
check "X1: valid state renders OK again (rc 0)"                "$rc" "0"
check "X1: ledger is quoted in the good render"               "$(grep -c -- '--ledger "/root/solana/ledger"' <<<"$V")" "1"

echo "== logrotate =="
L=$(_vcfg_render_logrotate)
check "logrotate USR1 solana"   "$(grep -c 'systemctl kill -s USR1 solana.service' <<<"$L")" "1"

echo "== R3: nothing renders PoH pinning any more =="
for fn in _vcfg_render_set_poh_affinity _vcfg_render_wait_and_pin _vcfg_render_poh_pin_service _vcfg_render_poh_pin_timer; do
    check_true "$fn is gone" "! declare -F $fn >/dev/null"
done

echo "== full generate writes files + bash -n =="
# SC2031: the earlier N16 subshell-local VALIDATOR_SH override is intentional.
# shellcheck disable=SC2031
export VALIDATOR_SH="$WORK/validator.sh" SOLANA_SERVICE="$WORK/solana.service" LOGROTATE_FILE="$WORK/logrotate"
# Where an older validatorcfg.sh was told to put its PoH scripts and units. Nothing reads these now; they keep that older
# code, run against this suite, from writing under /root and /etc, so that it fails its checks instead of ending the file.
export SET_POH_SCRIPT="$WORK/set_poh.sh" WAIT_PIN_SCRIPT="$WORK/wait_pin.sh" POH_PIN_SERVICE="$WORK/poh.service" POH_PIN_TIMER="$WORK/poh.timer"
validatorcfg_resolve_config
: >"$WORK/lncalls"; ln() { echo "ln $*" >>"$WORK/lncalls"; }   # record any symlink attempt
validatorcfg_generate >/dev/null 2>&1
check "H1: generate creates NO on-mount symlink (unit is a real /etc file)" "$(grep -c 'ln -sfn' "$WORK/lncalls")" "0"
ln() { :; }
check_true "validator.sh written + valid bash" "[[ -f \"$WORK/validator.sh\" ]] && bash -n \"$WORK/validator.sh\""
check_true "validator.sh is executable"        "[[ -x \"$WORK/validator.sh\" ]]"
check_true "solana.service and logrotate written" "[[ -f \"$WORK/solana.service\" && -f \"$WORK/logrotate\" ]]"
check "generate wrote no PoH script or unit (where an older one put them)" "$([[ -e "$WORK/set_poh.sh" || -e "$WORK/wait_pin.sh" || -e "$WORK/poh.service" || -e "$WORK/poh.timer" ]] && echo written || echo none)" "none"
# X1 (production path): generate must ABORT — and write no executable — when an
# untrusted value fails the render gate (a command-substitution failure does not
# propagate, so validatorcfg_generate captures-then-fails explicitly).
rm -f "$WORK/nope.sh" "$WORK/pwned"
# shellcheck disable=SC2030
( VALIDATOR_SH="$WORK/nope.sh"
  state_set ledger_path '/x")</dev/null;touch '"$WORK"'/pwned #'
  validatorcfg_resolve_config
  validatorcfg_generate ) >/dev/null 2>&1; rc=$?
check_true "X1: validatorcfg_generate ABORTS on hostile state" "[[ \"$rc\" != \"0\" ]]"
check_true "X1: generate wrote NO validator.sh"                "[[ ! -e \"$WORK/nope.sh\" ]]"
check_true "X1: generate executed nothing"                     "[[ ! -e \"$WORK/pwned\" ]]"
seed; validatorcfg_resolve_config   # restore clean state

echo "== R3: phase 6 over an older install removes its PoH pinning and restarts nothing =="
SYSCALLS="$WORK/systemctl-calls"
systemctl() {                        # records every call; SOLANA_ACTIVE_RC answers is-active
    echo "systemctl $*" >>"$SYSCALLS"
    [[ "$1" != is-active ]] || return "${SOLANA_ACTIVE_RC:-1}"
    return 0
}
# The recorded systemctl calls that name the validator's own unit (solana or solana.service; solana-poh-pin.* are other units), minus the
# whole lines the caller allows. An allowlist and not a list of verbs: a call nobody thought of (disable --now, --no-block restart, mask)
# is listed too. <none> when there is nothing else. (The first allowed line is a sentinel: an empty allowlist file is no pattern at all.)
solana_unit_calls() {                # <calls file> [allowed line]...
    local calls=$1 allow="$WORK/solana-allow" out; shift
    printf '%s\n' '(allowlist)' "$@" >"$allow"
    out=$(grep -E '^systemctl( .*)? solana(\.service)?( |$)' "$calls" | grep -vxFf "$allow" || true)
    rm -f "$allow"; printf '%s' "${out:-<none>}"
}
OH="$WORK/oldhome"; OU="$WORK/oldunits"
poh_files() { printf '%s\n' "$OH/set_poh_affinity.sh" "$OH/wait_and_pin_poh.sh" "$OU/solana-poh-pin.service" "$OU/solana-poh-pin.timer"; }
poh_left() { local f n=""; while IFS= read -r f; do [[ -e "$f" ]] && n+="${f##*/} "; done < <(poh_files); printf '%s' "${n:-<none>}"; }
old_install() {                      # what an older DeePloy left: the four files, a validator.sh with the flag, a unit with ExecStartPost
    local f; rm -rf "$OH" "$OU"; mkdir -p "$OH" "$OU"
    printf '#!/bin/bash\nexec agave-validator --poh-pinned-cpu-core "10"\n' >"$OH/validator.sh"
    printf '[Service]\nExecStart=%s/validator.sh\nExecStartPost=/bin/systemctl --no-block start solana-poh-pin.service\n' "$OH" >"$OU/solana.service"
    while IFS= read -r f; do echo old >"$f"; done < <(poh_files)
}
# SC2030/SC2031: the fixture's paths are set in the subshell on purpose, the suite's own are not to change.
# shellcheck disable=SC2030,SC2031
phase6() {                           # resolve + generate against the fixture, in its own shell; output to $1
    ( export VALIDATOR_SH="$OH/validator.sh" SOLANA_SERVICE="$OU/solana.service" LOGROTATE_FILE="$WORK/logrotate-old"
      state_set solana_home "$OH"
      validatorcfg_resolve_config && validatorcfg_generate ) >"$1" 2>&1
}
old_install; : >"$SYSCALLS"
SOLANA_ACTIVE_RC=0 phase6 "$WORK/p6a.out"
check "older install: the four files are removed"              "$(poh_left)" "<none>"
check "older install: one 'removed' line per file, four in all" \
      "$(grep -c "removed $OH/set_poh_affinity.sh" "$WORK/p6a.out")$(grep -c "removed $OH/wait_and_pin_poh.sh" "$WORK/p6a.out")$(grep -c "removed $OU/solana-poh-pin.service" "$WORK/p6a.out")$(grep -c "removed $OU/solana-poh-pin.timer" "$WORK/p6a.out")|$(grep -c ' removed ' "$WORK/p6a.out")" "1111|4"
check "older install: timer disabled and stopped first"      "$(grep -m1 'poh-pin' "$SYSCALLS")" "systemctl disable --now solana-poh-pin.timer"
check "older install: the service stopped and disabled"       "$(grep -c '^systemctl stop solana-poh-pin.service$' "$SYSCALLS")|$(grep -c '^systemctl disable solana-poh-pin.service$' "$SYSCALLS")" "1|1"
check "older install: daemon-reload after the timer is disabled" \
      "$(awk '/disable --now solana-poh-pin.timer/ {t = NR} /^systemctl daemon-reload$/ && t && !r {r = NR} END {print (t && r && r > t) ? "after" : "t=" t " r=" r}' "$SYSCALLS")" "after"
check "older install: validator.sh rewritten without the flag" "$(grep -c -- 'poh-pinned-cpu-core' "$OH/validator.sh")" "0"
check "older install: solana.service rewritten without ExecStartPost" "$(grep -c 'ExecStartPost' "$OU/solana.service")" "0"
check "older install: control — the answer to is-active was asked" "$(grep -c '^systemctl is-active --quiet solana.service$' "$SYSCALLS")" "1"
# Phase 6 asks whether solana.service is running and does nothing else with it (the PoH-pin units are other units).
check "older install: the only systemctl call that names solana.service is the is-active question (allowlist)" \
      "$(solana_unit_calls "$SYSCALLS" 'systemctl is-active --quiet solana.service')" "<none>"
check "older install: reset-failed for both PoH-pin units, once" \
      "$(grep -c '^systemctl reset-failed solana-poh-pin.service solana-poh-pin.timer$' "$SYSCALLS")" "1"
check "older install: says the new validator.sh takes effect at the next planned restart" "$(grep -c 'new validator.sh takes effect at the next planned restart' "$WORK/p6a.out")" "1"
check "older install: and that a staked node goes to the standby first" "$(grep -c 'a staked node: move it to the standby first' "$WORK/p6a.out")" "1"
# A second run: nothing left to remove, nothing changed, nothing to say.
: >"$SYSCALLS"; SOLANA_ACTIVE_RC=0 phase6 "$WORK/p6b.out"
check "re-run: no PoH-pin call, no 'removed' line"           "$(grep -c 'poh-pin' "$SYSCALLS")|$(grep -c ' removed ' "$WORK/p6b.out")" "0|0"
check "re-run: validator.sh unchanged, so no restart notice" "$(grep -c 'takes effect at the next planned restart' "$WORK/p6b.out")" "0"
# A stopped validator picks the new file up at its next start anyway: no notice.
old_install; : >"$SYSCALLS"
SOLANA_ACTIVE_RC=3 phase6 "$WORK/p6c.out"
check "solana not running: files removed, no restart notice" "$(poh_left)|$(grep -c 'takes effect at the next planned restart' "$WORK/p6c.out")" "<none>|0"
# Only part of it left (units but no scripts, and the other way round): still one line per file.
old_install; rm -f "$OH/set_poh_affinity.sh" "$OH/wait_and_pin_poh.sh"; : >"$SYSCALLS"
SOLANA_ACTIVE_RC=0 phase6 "$WORK/p6d.out"
check "only the units left: both removed, two lines"         "$(poh_left)|$(grep -c ' removed ' "$WORK/p6d.out")" "<none>|2"
old_install; rm -f "$OU/solana-poh-pin.service" "$OU/solana-poh-pin.timer"; : >"$SYSCALLS"
SOLANA_ACTIVE_RC=0 phase6 "$WORK/p6e.out"
check "only the scripts left: both removed, two lines"       "$(poh_left)|$(grep -c ' removed ' "$WORK/p6e.out")" "<none>|2"
# A dry run removes nothing and says nothing was removed.
old_install; : >"$SYSCALLS"
# shellcheck disable=SC2030,SC2031
( DRY_RUN=1; SOLANA_ACTIVE_RC=0; export VALIDATOR_SH="$OH/validator.sh" SOLANA_SERVICE="$OU/solana.service" LOGROTATE_FILE="$WORK/logrotate-old"
  state_set solana_home "$OH"; validatorcfg_resolve_config && validatorcfg_generate ) >"$WORK/p6f.out" 2>&1
check "dry-run: the four files are still there"              "$(poh_left)" "set_poh_affinity.sh wait_and_pin_poh.sh solana-poh-pin.service solana-poh-pin.timer "
check "dry-run: no 'removed' line, no systemctl call"        "$(grep -c ' removed ' "$WORK/p6f.out")|$(grep -c . "$SYSCALLS")" "0|0"
check "dry-run: and the old validator.sh is untouched"       "$(grep -c 'poh-pinned-cpu-core' "$OH/validator.sh")" "1"
check "dry-run: a running solana, but nothing was written, so no restart notice" "$(grep -c 'takes effect at the next planned restart' "$WORK/p6f.out")" "0"
# The phase-6 files run systemctl on the validator's unit in two lines only: the is-active question, and the logrotate template's
# `systemctl kill -s USR1` (a signal in a rendered file, which phase 6 does not run). An allowlist of whole lines.
STATIC_SOL=$(grep -hE 'systemctl' "$ROOT/lib/validatorcfg.sh" "$ROOT/lib/nic.sh" \
    | grep -E '(^|[^A-Za-z0-9_-])solana(\.service)?([^A-Za-z0-9_.-]|$)' \
    | grep -vxF -e '    if (( changed )) && ! is_dry_run && systemctl is-active --quiet solana.service 2>/dev/null; then' \
                -e '    systemctl kill -s USR1 solana.service' || true)
check "static: lib/validatorcfg.sh and lib/nic.sh run systemctl on solana.service only for the is-active question and the logrotate kill (allowlist)" \
      "${STATIC_SOL:-<none>}" "<none>"
state_set solana_home /root/solana; seed; validatorcfg_resolve_config
unset -f systemctl solana_unit_calls poh_files poh_left old_install phase6; systemctl() { :; }

echo "== version floor at RENDER: phase 6 is reachable without phase 4 =="
# The generated validator.sh's own header tells the operator to regenerate with
# `install --only 6`, which skips phase 4 entirely — so a box built on an older
# client can land here and be handed flags its binary rejects.
seed; state_set dz_enabled false
state_set jito_tag v4.0.0-jito
VFOUT=$( ( unset JITO_TAG; MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 ); VFRC=$?
check "recorded 4.0.0 -> render refused"        "$VFRC" "1"
check "refusal names the render, not the build" "$(grep -c 'refusing to render validator.sh' <<<"$VFOUT")" "1"
check "refusal names the flag the render passes, none it no longer does" "$(grep -c 'passes --no-xdp where XDP is off, and --no-xdp first exists in' <<<"$VFOUT")|$(grep -c 'poh-pinned-cpu-core' <<<"$VFOUT")" "1|0"
check "refusal points at the upgrade path"      "$(grep -c 'upgrade' <<<"$VFOUT")" "1"
state_set jito_tag v4.2.1-jito
( unset JITO_TAG; MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "recorded 4.2.1 -> proceeds"              "$?" "0"
# env/conf tag WINS over the recorded one (same precedence as everywhere else)
( JITO_TAG=v4.0.0-jito MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "env tag below floor overrides good state -> refused" "$?" "1"
state_set jito_tag v4.0.0-jito
( JITO_TAG=v4.2.1-jito MEV_MODE=bam validatorcfg_resolve_config ) >/dev/null 2>&1
check "env tag above floor overrides old state -> ok"       "$?" "0"
# Below the recommendation: rendered, with one warning that names it.
VRW=$( ( JITO_TAG=v4.2.1-jito MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 ); VRWRC=$?
check "env tag below the recommendation -> rendered (rc 0)" "$VRWRC" "0"
check "  with one warning naming the recommendation"        "$(grep -c "below the recommended ${DEEPLOY_RECOMMENDED_JITO_TAG:-?}" <<<"$VRW")" "1"
VRN=$( ( JITO_TAG="${DEEPLOY_RECOMMENDED_JITO_TAG:-v4.3.2-jito}" MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 )
check "the recommended tag -> no such warning"              "$(grep -c 'below the recommended' <<<"$VRN")" "0"
# nothing known at all -> proceed, but SAY what is being assumed
state_clear jito_tag
VFW=$( ( unset JITO_TAG; MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 ); VFWRC=$?
check "no tag anywhere -> proceeds"             "$VFWRC" "0"
check "no tag -> warns and names the assumption" "$(grep -c 'assuming >=' <<<"$VFW")" "1"
state_set jito_tag v4.2.1-jito   # leave a supported tag for any later section

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
