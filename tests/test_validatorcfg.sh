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
    state_set poh_core 10
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
check "poh pinned core = 10"   "$(grep -c -- '--poh-pinned-cpu-core "10"' <<<"$V")" "1"
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

echo "== N4: generated header advertises a RUNNABLE regenerate hint (rendered, not template) =="
check "header: runnable numeric form via DEEPLOY_CMD" "$(grep -c -- 'regenerate via: ./deeploy.sh install --only 6' <<<"$V")" "1"
check "header: NOT the broken '--only validatorcfg'"  "$(grep -c -- '--only validatorcfg' <<<"$V")" "0"

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
check "ExecStartPost poh-pin"   "$(grep -c 'ExecStartPost=/bin/systemctl --no-block start solana-poh-pin.service' <<<"$S")" "1"
check "metrics = BAM endpoint"  "$(grep -c 'bam-public-metrics.jito.wtf' <<<"$S")" "1"
check "RequiresMountsFor (two-nvme)" "$(grep -c 'RequiresMountsFor=/mnt/accounts /mnt/ledger' <<<"$S")" "1"
check "ExecStart = validator.sh" "$(grep -c 'ExecStart=/root/solana/validator.sh' <<<"$S")" "1"
check "R4: StartLimitIntervalSec=0 (rate limiter disabled)" "$(grep -c '^StartLimitIntervalSec=0' <<<"$S")" "1"
check "R4: NOT the permanent-down =5"                        "$(grep -c 'StartLimitIntervalSec=5' <<<"$S")" "0"
# RequiresMountsFor must be ABSENT on root layout (no separate mounts to wait on).
state_set disk_layout root; validatorcfg_resolve_config
check "no RequiresMountsFor on root layout" "$(grep -c 'RequiresMountsFor' "$(_vcfg_render_solana_service >"$WORK/sv"; echo "$WORK/sv")")" "0"
state_set disk_layout two-nvme

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

echo "== I3: poh-pin service uses Requisite= (never pulls solana.service UP) =="
PS=$(_vcfg_render_poh_pin_service)
check "I3: Requisite=solana.service"             "$(grep -c '^Requisite=solana.service' <<<"$PS")" "1"
check "I3: NOT Requires= (would start solana)"   "$(grep -c '^Requires=solana.service' <<<"$PS")" "0"
check "I3: After=solana.service kept (ordering)" "$(grep -c '^After=solana.service' <<<"$PS")" "1"

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

echo "== poh scripts + timer + logrotate =="
P=$(_vcfg_render_set_poh_affinity)
check "set_poh: taskset core 10"   "$(grep -c 'taskset -cp 10 ' <<<"$P")" "1"
check "set_poh: exit 0 if already" "$(grep -c 'already_set"; exit 0' <<<"$P")" "1"
check "set_poh: no placeholder left" "$(grep -c '__POH_CORE__' <<<"$P")" "0"
W=$(_vcfg_render_wait_and_pin)
check "wait: no 'solana catchup' (R10-4)"     "$(grep -cE 'catchup|SOLANA_BIN' <<<"$W")" "0"
check "wait: the node's RPC on RPC_PORT"      "$(grep -c '^NODE_RPC="http://127.0.0.1:8899"$' <<<"$W")" "1"
check "wait: the cluster RPC substituted"     "$(grep -c "^CLUSTER_RPC=\"$DEFAULT_PUBLIC_RPC\"\$" <<<"$W")" "1"
check "wait: the caught-up window substituted" "$(grep -c "^CAUGHT_UP_MAX_BEHIND=${CAUGHT_UP_MAX_BEHIND}\$" <<<"$W")" "1"
check "wait: timeout 3600 s, a poll per 15 s" "$(grep -c '^MAX_WAIT_SECONDS=3600$' <<<"$W")|$(grep -c '^CHECK_INTERVAL=15$' <<<"$W")" "1|1"
check "wait: no placeholder left"             "$(grep -cE '__[A-Z_]+__' <<<"$W")" "0"
# H4: a failed pin must NOT report success.
check "H4: set_poh captures taskset exit"        "$(grep -c 'rc=\$?' <<<"$P")" "1"
check "H4: set_poh has a taskset-failure branch"  "$(grep -c 'taskset_failed' <<<"$P")" "1"
check "H4: wait_and_pin captures pin exit"        "$(grep -c 'pin_rc=\$?' <<<"$W")" "1"
check "H4: wait_and_pin no hardcoded final exit 0" "$(grep -cE '^exit 0$' <<<"$W")" "0"
T=$(_vcfg_render_poh_pin_timer)
check "timer OnBootSec=1min"    "$(grep -c 'OnBootSec=1min' <<<"$T")" "1"
check "timer OnUnitActiveSec=1h" "$(grep -c 'OnUnitActiveSec=1h' <<<"$T")" "1"
L=$(_vcfg_render_logrotate)
check "logrotate USR1 solana"   "$(grep -c 'systemctl kill -s USR1 solana.service' <<<"$L")" "1"

echo "== R10-4: wait_and_pin_poh.sh, run — a status line every poll, 'solana' silent =="
# The rendered script with stubs first on PATH. curl answers getSlot from $US
# (the node, 127.0.0.1) and $THEM (the cluster): DOWN = no answer (curl's exit
# and message for a refused connection), ERR = a JSON-RPC error, SP<n> = <n>
# with spaces in the JSON; each call's arguments go to $SLOTS. date gives a
# fixed clock, 1000 for +%s; with $JUMP set, every +%s after the first gives
# 1000 + $JUMP. sleep returns at once, and the pin script logs to $WORK/pinned.
# Through a pipe, 'solana catchup' prints nothing while the node is behind (its
# spinner is not drawn off a terminal); the solana stub does the same until it
# is killed, and appends its PID to $STUBS.
SB="$WORK/stubbin"; STUBS="$WORK/stubs"; mkdir -p "$SB" "$WORK/inst/active_release/bin"; : >"$STUBS"
cat >"$SB/curl" <<'EOF'
#!/bin/bash
url=${!#}; echo "$*" >>"$SLOTS"
case "$url" in http://127.0.0.1:*) a=$US ;; *) a=$THEM ;; esac
case "$a" in
    DOWN) echo "curl: (7) Failed to connect to ${url#*//} after 0 ms: Couldn't connect to server" >&2; exit 7 ;;
    ERR)  echo '{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":1}' ;;
    SP*)  printf '{"jsonrpc": "2.0", "result" : %s, "id": 1}\n' "${a#SP}" ;;
    *)    printf '{"jsonrpc":"2.0","result":%s,"id":1}\n' "$a" ;;
esac
EOF
cat >"$SB/date" <<'EOF'
#!/bin/bash
if [ "$1" != +%s ]; then echo T
elif [ -n "${JUMP:-}" ] && [ -e "$JUMPF" ]; then echo $((1000 + JUMP))
else [ -z "${JUMP:-}" ] || : >"$JUMPF"; echo 1000; fi
EOF
printf '#!/bin/bash\nexit 0\n' >"$SB/systemctl"; printf '#!/bin/bash\nexit 0\n' >"$SB/logger"; printf '#!/bin/bash\nexit 0\n' >"$SB/sleep"
printf '#!/bin/bash\necho $$ >>"%s"\nexec /bin/sleep 120\n' "$STUBS" >"$WORK/inst/active_release/bin/solana"
printf '#!/bin/bash\necho pinned >>"%s"\nexit 3\n' "$WORK/pinned" >"$WORK/pin.sh"
chmod +x "$SB"/* "$WORK/inst/active_release/bin/solana" "$WORK/pin.sh"
RPC_PORT=8901 SOLANA_INSTALL_DIR="$WORK/inst" SET_POH_SCRIPT="$WORK/pin.sh" _vcfg_render_wait_and_pin >"$WORK/wait.sh"
# exec: the background job is the script itself, so killing it stops the loop.
JUMP=""
run_wait() { PATH="$SB:$PATH" SLOTS="$WORK/slots" US=$US THEM=$THEM JUMP=$JUMP JUMPF="$WORK/jumped" exec bash "$WORK/wait.sh"; }
# within <secs> <ERE> <cmd...>: runs <cmd> in the background and prints the
# first line of its output matching <ERE> as soon as there is one, or nothing
# after <secs>; then kills <cmd> and every stub still waiting. The whole output
# stays in $WORK/within.out.
within() {
    local secs=$1 re=$2 out="$WORK/within.out" pid i; shift 2
    "$@" >"$out" 2>&1 &
    pid=$!
    for (( i = 0; i < secs * 10; i++ )); do
        grep -qE "$re" "$out" && break
        command sleep 0.1
    done
    { kill -KILL "$pid"; wait "$pid"; xargs kill -KILL <"$STUBS"; } 2>/dev/null
    : >"$STUBS"
    grep -m1 -E "$re" "$out"
}
# ends_within <secs> <cmd...>: runs <cmd> in the background; prints "rc <n>" if
# it ends within <secs>, else "running" (and kills it and every stub). The
# output stays in $WORK/within.out.
ends_within() {
    local secs=$1 pid i; shift
    "$@" >"$WORK/within.out" 2>&1 &
    pid=$!
    for (( i = 0; i < secs * 10; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        command sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        { kill -KILL "$pid"; wait "$pid"; xargs kill -KILL <"$STUBS"; } 2>/dev/null; : >"$STUBS"
        echo running
    else wait "$pid"; echo "rc $?"; fi
}
US=10 THEM=95
check "behind -> a status line within 5 s"      "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): 85 slots behind (us:10 them:95)"
US=96 THEM=100
check "4 behind -> caught up (the CLI's window)" "$(within 5 'Caught up' run_wait)" "[T] Caught up (us:96 them:100)"
US=95 THEM=100
check "5 behind -> '5 slots behind'"            "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): 5 slots behind (us:95 them:100)"
US=SP10 THEM=SP95
check "spaces in the JSON are read"             "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): 85 slots behind (us:10 them:95)"
US=DOWN THEM=95
check "the node's RPC silent -> says so (RPC_PORT)" "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): no slot from the node's RPC at http://127.0.0.1:8901"
check "the node's RPC silent -> no curl message" "$(grep -c '^curl:' "$WORK/within.out")" "0"
US=ERR THEM=95
check "a JSON-RPC error is no slot"             "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): no slot from the node's RPC at http://127.0.0.1:8901"
US=10 THEM=DOWN
check "the cluster RPC silent -> says so"       "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): no slot from the cluster RPC at $DEFAULT_PUBLIC_RPC (us:10)"
US=DOWN THEM=DOWN
check "both silent -> the node's RPC is named"  "$(within 5 'Not caught up' run_wait)" "[T] Not caught up yet (elapsed 0s): no slot from the node's RPC at http://127.0.0.1:8901"
US=100 THEM=100; : >"$WORK/slots"
check "caught up -> pins, logs the pin's exit"  "$(within 5 'PoH pin completed' run_wait)" "[T] PoH pin completed (exit 3)"
check "caught up -> logged with both slots"     "$(grep -c '^\[T\] Caught up (us:100 them:100)$' "$WORK/within.out")" "1"
check "the cluster's slot is read first"        "$(sed 's/.* //' "$WORK/slots" | tr '\n' ' ')" "$DEFAULT_PUBLIC_RPC http://127.0.0.1:8901 "
check "each read is capped at 5 s"              "$(grep -c -- ' -m 5 ' "$WORK/slots")" "2"
check "each read is getSlot at confirmed"       "$(grep -cF '"method":"getSlot","params":[{"commitment":"confirmed"}]' "$WORK/slots")" "2"
check "each read sends Content-Type: application/json" "$(grep -cF 'Content-Type: application/json' "$WORK/slots")" "2"
US=101 THEM=100
check "ahead -> caught up"                      "$(within 5 'Caught up' run_wait)" "[T] Caught up (us:101 them:100)"
US=10 THEM=95 JUMP=3601; : >"$WORK/pinned"; rm -f "$WORK/jumped"
check "past 3600 s -> FATAL, exit 1, no pin"    "$(ends_within 5 run_wait)|$(grep -c '^\[T\] FATAL: timeout after 3600s$' "$WORK/within.out")|$(wc -l <"$WORK/pinned" | tr -d ' ')" "rc 1|1|0"
JUMP=""

echo "== full generate writes files + bash -n =="
# SC2031: the earlier N16 subshell-local VALIDATOR_SH override is intentional.
# shellcheck disable=SC2031
export VALIDATOR_SH="$WORK/validator.sh" SOLANA_SERVICE="$WORK/solana.service" \
    SET_POH_SCRIPT="$WORK/set_poh.sh" WAIT_PIN_SCRIPT="$WORK/wait_pin.sh" \
    LOGROTATE_FILE="$WORK/logrotate" POH_PIN_SERVICE="$WORK/poh.service" POH_PIN_TIMER="$WORK/poh.timer"
validatorcfg_resolve_config
: >"$WORK/lncalls"; ln() { echo "ln $*" >>"$WORK/lncalls"; }   # record any symlink attempt
validatorcfg_generate >/dev/null 2>&1
check "H1: generate creates NO on-mount symlink (unit is a real /etc file)" "$(grep -c 'ln -sfn' "$WORK/lncalls")" "0"
ln() { :; }
check_true "validator.sh written + valid bash" "[[ -f \"$WORK/validator.sh\" ]] && bash -n \"$WORK/validator.sh\""
check_true "set_poh written + valid bash"      "bash -n \"$WORK/set_poh.sh\""
check_true "wait_pin written + valid bash"     "bash -n \"$WORK/wait_pin.sh\""
check_true "validator.sh is executable"        "[[ -x \"$WORK/validator.sh\" ]]"
# X1 (production path): generate must ABORT — and write no executable — when an
# untrusted value fails the render gate (a command-substitution failure does not
# propagate, so validatorcfg_generate captures-then-fails explicitly).
rm -f "$WORK/nope.sh" "$WORK/pwned"
( VALIDATOR_SH="$WORK/nope.sh"
  state_set ledger_path '/x")</dev/null;touch '"$WORK"'/pwned #'
  validatorcfg_resolve_config
  validatorcfg_generate ) >/dev/null 2>&1; rc=$?
check_true "X1: validatorcfg_generate ABORTS on hostile state" "[[ \"$rc\" != \"0\" ]]"
check_true "X1: generate wrote NO validator.sh"                "[[ ! -e \"$WORK/nope.sh\" ]]"
check_true "X1: generate executed nothing"                     "[[ ! -e \"$WORK/pwned\" ]]"
seed; validatorcfg_resolve_config   # restore clean state

echo "== version floor at RENDER: phase 6 is reachable without phase 4 =="
# The generated validator.sh's own header tells the operator to regenerate with
# `install --only 6`, which skips phase 4 entirely — so a box built on an older
# client can land here and be handed flags its binary rejects.
seed; state_set dz_enabled false
state_set jito_tag v4.0.0-jito
VFOUT=$( ( unset JITO_TAG; MEV_MODE=bam validatorcfg_resolve_config ) 2>&1 ); VFRC=$?
check "recorded 4.0.0 -> render refused"        "$VFRC" "1"
check "refusal names the render, not the build" "$(grep -c 'refusing to render validator.sh' <<<"$VFOUT")" "1"
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
