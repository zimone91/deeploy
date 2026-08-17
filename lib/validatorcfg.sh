#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/validatorcfg.sh   (Phase 6: validator config)
# Generates the runtime artifacts from state/config:
#   validator.sh (labeled arg-arrays), solana.service (XDP caps, Nice,
#   OOMScoreAdjust, ExecStartPost->poh-pin), logrotate, set_poh_affinity.sh,
#   wait_and_pin_poh.sh, and the solana-poh-pin service+timer.
#
# POH_CORE flows in from state (single source of truth -> both the
# --poh-pinned-cpu-core arg AND set_poh_affinity.sh). RETRANSMIT ALWAYS states
# the XDP decision (flags, or --no-xdp) — 4.2 made XDP opt-out. JITO is
# BAM by default (commission-bps tied to mode); the DZ multicast shred is
# appended as a 2nd --shred-receiver-address when enabled.
#
# Requires: common.sh + constants.sh sourced. Output paths are overridable for
# tests; everything goes through write_file (dry-run safe, backed up).
# ============================================================================

[[ -n "${_DEEPLOY_VALIDATORCFG_SOURCED:-}" ]] && return 0
_DEEPLOY_VALIDATORCFG_SOURCED=1

SOLANA_INSTALL_DIR="${SOLANA_INSTALL_DIR:-$HOME/.local/share/solana/install}"

# This module's phase number in deeploy.sh's install chain. Used for the
# generated header's "regenerate" hint so the printed command stays RUNNABLE —
# the old hint advertised '--only validatorcfg', a form --only never accepted
# (N4). Kept in sync with phase_name() by a test in test_deeploy.sh.
VALIDATORCFG_PHASE=6

# --- config resolution -------------------------------------------------------
validatorcfg_resolve_config() {
    SOLANA_HOME="$(state_get solana_home /root/solana)"
    SYNC_IDENTITY="$(state_get sync_identity "$SOLANA_HOME/unstaked-identity.json")"
    VOTE_ACCOUNT_PUBKEY="$(state_get vote_account_pubkey "${VOTE_ACCOUNT_PUBKEY:-}")"
    POH_CORE="$(state_get poh_core "${POH_CORE:-2}")"
    LEDGER_PATH="$(state_get ledger_path "$SOLANA_HOME/ledger")"
    ACCOUNTS_PATH="$(state_get accounts_path /mnt/accounts/solana/accounts)"
    SNAPSHOTS_PATH="$(state_get snapshots_path "$SOLANA_HOME/snapshots")"
    RETRANSMIT_SUPPORTED="$(state_get retransmit_supported 0)"
    RETRANSMIT_ZERO_COPY="$(state_get retransmit_zero_copy 0)"
    XDP_CORES="$(state_get xdp_cores "")"

    # Version floor for the RENDER, not just the build (phase 4 has its own).
    # This phase is reachable without phase 4 — the generated validator.sh's own
    # header tells the operator to regenerate with `install --only 6`, so a box
    # built on an older client can land here and get flags its binary rejects.
    # Env/conf wins over the recorded build tag, so an explicit JITO_TAG is
    # validated even on a box with no build recorded yet.
    local _vcfg_tag _vcfg_why
    _vcfg_tag="${JITO_TAG:-$(state_get jito_tag "")}"
    if [[ -z "$_vcfg_tag" ]]; then
        warn "no recorded jito-solana build tag — assuming >= ${DEEPLOY_MIN_JITO_TAG}; validator.sh is rendered with flags that require it"
    else
        _vcfg_why="$(deeploy_tag_floor_problem "$_vcfg_tag")" \
            || fail "refusing to render validator.sh for '${_vcfg_tag}': ${_vcfg_why}. The rendered flags (--no-xdp, --poh-pinned-cpu-core) first exist in ${DEEPLOY_MIN_JITO_TAG}, so this binary would reject them and the validator would not start. Upgrade the client first — '${DEEPLOY_CMD} upgrade' to ${DEEPLOY_MIN_JITO_TAG} or newer — then regenerate."
    fi

    # Network / threads / snapshot knobs (memo defaults).
    GOSSIP_PORT="${GOSSIP_PORT:-8001}"
    RPC_PORT="${RPC_PORT:-8899}"
    RPC_BIND_ADDRESS="${RPC_BIND_ADDRESS:-127.0.0.1}"
    RPC_THREADS="${RPC_THREADS:-8}"
    DYNAMIC_PORT_RANGE="${DYNAMIC_PORT_RANGE:-8900-9000}"
    REPLAY_THREADS="${REPLAY_THREADS:-14}"
    LIMIT_LEDGER_SIZE="${LIMIT_LEDGER_SIZE:-50000000}"
    MIN_SNAPSHOT_DOWNLOAD_SPEED="${MIN_SNAPSHOT_DOWNLOAD_SPEED:-83886080}"
    FULL_SNAPSHOT_INTERVAL_SLOTS="${FULL_SNAPSHOT_INTERVAL_SLOTS:-102400}"
    INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS="${INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS:-5120}"

    # MEV (BAM default; commission-bps tied to mode).
    MEV_MODE="${MEV_MODE:-bam}"
    BAM_URL="${BAM_URL:-$(state_get suggested_bam_url "")}"
    BLOCK_ENGINE_URL="${BLOCK_ENGINE_URL:-$(state_get suggested_block_engine_url "")}"
    SHRED_RECEIVER_ADDRESS="${SHRED_RECEIVER_ADDRESS:-$(state_get suggested_shred_receiver "")}"
    RELAYER_URL="${RELAYER_URL:-http://127.0.0.1:11226}"
    # Fail fast when the MEV endpoints are empty (region scan failed + no override):
    # the renderer would otherwise emit bare --bam-url/--block-engine-url/
    # --shred-receiver-address flags (argv misalignment) that only surface as an
    # unattended Phase 8 crash-loop. Turn that into an actionable Phase 6 error. (R3)
    local _mev_missing=""
    [[ -n "$BLOCK_ENGINE_URL" ]]      || _mev_missing+=" BLOCK_ENGINE_URL"
    [[ -n "$SHRED_RECEIVER_ADDRESS" ]] || _mev_missing+=" SHRED_RECEIVER_ADDRESS"
    if [[ "$MEV_MODE" == "relayer" ]]; then
        [[ -n "$RELAYER_URL" ]] || _mev_missing+=" RELAYER_URL"
    else
        [[ -n "$BAM_URL" ]] || _mev_missing+=" BAM_URL"
    fi
    [[ -z "$_mev_missing" ]] || fail "MEV endpoints unset (${_mev_missing# }) — the region scan likely failed. Set them in deeploy.conf / env (or re-run 'import --rescore'). Refusing to render a validator with empty MEV flags — it would crash-loop at start."
    # commission-bps: mode-derived DEFAULT (bam->0, relayer->1000) but PROMPTED
    # at install so the operator can override — never set silently (0 is required
    # by many pools, but some want otherwise).
    local commission_default=0
    [[ "$MEV_MODE" == "relayer" ]] && commission_default=1000
    if [[ -z "${COMMISSION_BPS:-}" ]]; then
        ask "Validator MEV commission in bps (0 is required by many pools)" "$commission_default"
        COMMISSION_BPS="$REPLY"
    fi
    # N9: bounded 0-10000 whether prompted, env-, or conf-provided (shared bps
    # type). An out-of-range value (e.g. 20000) used to render fine and only
    # surface as an unattended post-reboot agave crash-loop.
    _cfg_validate_type bps "$COMMISSION_BPS" \
        || fail "COMMISSION_BPS '${COMMISSION_BPS}' invalid — must be an integer 0-10000 (basis points)"
    # The 2nd shred-receiver address (DZ multicast) is gated on the SINGLE
    # "Enable DoubleZero?" decision made EARLY in Phase 1 (dz_should_enable) and
    # recorded to state. Phase 6 only READS it — no prompt here (the old in-phase
    # prompt was buried in a redirect and invisible; the decision now lives in
    # Phase 1's visible prompt).
    DZ_ENABLED_RESOLVED="$(state_get dz_enabled false)"

    # Record the MEV/region selections to state so `deeploy export` can capture them.
    state_set mev_mode "$MEV_MODE"
    state_set bam_url "$BAM_URL"
    state_set block_engine_url "$BLOCK_ENGINE_URL"
    state_set shred_receiver "$SHRED_RECEIVER_ADDRESS"
    state_set commission_bps "$COMMISSION_BPS"

    # Metrics (BAM community endpoint by default).
    SOLANA_METRICS_CONFIG="${SOLANA_METRICS_CONFIG:-$SOLANA_METRICS_BAM}"
    # N16: env-only render vector (deliberately NOT in the conf whitelist) that
    # lands raw in a systemd Environment= line. Its legit shape carries ',' and
    # '=' (host=...,db=...,u=...,p=...), so no strict type fits — assert no
    # shell/unit metacharacters instead, fail-closed like the X1 render gate.
    case "$SOLANA_METRICS_CONFIG" in
        *'"'*|*"'"*|*'$'*|*'`'*|*';'*|*$'\n'*)
            fail "SOLANA_METRICS_CONFIG contains a forbidden character (quote/backtick/\$/;/newline) — refusing to render it into solana.service" ;;
    esac

    # Output paths.
    VALIDATOR_SH="${VALIDATOR_SH:-$SOLANA_HOME/validator.sh}"
    # Install the unit as a REAL file under /etc (root fs), NOT on $SOLANA_HOME (a
    # ledger-mount symlink): systemd loads enabled units at early boot, before
    # local-fs mounts, so an on-mount unit is unreadable then and silently dropped
    # from the boot transaction — the validator would not auto-start (H1).
    SOLANA_SERVICE="${SOLANA_SERVICE:-/etc/systemd/system/solana.service}"
    SET_POH_SCRIPT="${SET_POH_SCRIPT:-$SOLANA_HOME/set_poh_affinity.sh}"
    WAIT_PIN_SCRIPT="${WAIT_PIN_SCRIPT:-$SOLANA_HOME/wait_and_pin_poh.sh}"
    LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/solana}"
    POH_PIN_SERVICE="${POH_PIN_SERVICE:-/etc/systemd/system/solana-poh-pin.service}"
    POH_PIN_TIMER="${POH_PIN_TIMER:-/etc/systemd/system/solana-poh-pin.timer}"

    [[ -n "$VOTE_ACCOUNT_PUBKEY" ]] || fail "vote_account_pubkey not set (run Phase 5 keys first)"
}

# --- validator.sh ------------------------------------------------------------
# Fail-closed gate at the code-generation point (X1): every UNTRUSTED value that
# gets interpolated into validator.sh (a root-executed shell script) must pass
# its type validator first. Reuses the SAME _cfg_validate_type as the config
# parser (single source of truth) — so this should never fire if the config
# layer already validated, which is exactly why it belongs here (defense in
# depth at the point where data becomes an executable).
_vcfg_assert_render_safe() {
    local bad=""
    _cfg_validate_type path     "$SYNC_IDENTITY"                    || bad+=" SYNC_IDENTITY"
    _cfg_validate_type pubkey   "$VOTE_ACCOUNT_PUBKEY"              || bad+=" VOTE_ACCOUNT_PUBKEY"
    _cfg_validate_type port     "$GOSSIP_PORT"                      || bad+=" GOSSIP_PORT"
    _cfg_validate_type port     "$RPC_PORT"                         || bad+=" RPC_PORT"
    _cfg_validate_type ip       "$RPC_BIND_ADDRESS"                 || bad+=" RPC_BIND_ADDRESS"
    _cfg_validate_type int      "$RPC_THREADS"                      || bad+=" RPC_THREADS"
    _cfg_validate_type portrange "$DYNAMIC_PORT_RANGE"              || bad+=" DYNAMIC_PORT_RANGE"
    _cfg_validate_type int      "$REPLAY_THREADS"                   || bad+=" REPLAY_THREADS"
    _cfg_validate_type int      "$POH_CORE"                         || bad+=" POH_CORE"
    _cfg_validate_type path     "$SOLANA_HOME"                      || bad+=" SOLANA_HOME"
    _cfg_validate_type path     "$LEDGER_PATH"                      || bad+=" LEDGER_PATH"
    _cfg_validate_type path     "$ACCOUNTS_PATH"                    || bad+=" ACCOUNTS_PATH"
    _cfg_validate_type path     "$SNAPSHOTS_PATH"                   || bad+=" SNAPSHOTS_PATH"
    _cfg_validate_type int      "$LIMIT_LEDGER_SIZE"                || bad+=" LIMIT_LEDGER_SIZE"
    _cfg_validate_type int      "$MIN_SNAPSHOT_DOWNLOAD_SPEED"      || bad+=" MIN_SNAPSHOT_DOWNLOAD_SPEED"
    _cfg_validate_type int      "$FULL_SNAPSHOT_INTERVAL_SLOTS"     || bad+=" FULL_SNAPSHOT_INTERVAL_SLOTS"
    _cfg_validate_type int      "$INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS" || bad+=" INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS"
    _cfg_validate_type hostport "$SHRED_RECEIVER_ADDRESS"          || bad+=" SHRED_RECEIVER_ADDRESS"
    _cfg_validate_type bps      "$COMMISSION_BPS"                  || bad+=" COMMISSION_BPS"
    _cfg_validate_type url      "$BLOCK_ENGINE_URL"                || bad+=" BLOCK_ENGINE_URL"
    if [[ "$MEV_MODE" == "relayer" ]]; then
        _cfg_validate_type url  "$RELAYER_URL"                     || bad+=" RELAYER_URL"
    else
        _cfg_validate_type url  "$BAM_URL"                         || bad+=" BAM_URL"
    fi
    # XDP_CORES is interpolated only when the RETRANSMIT block is included.
    if [[ "$RETRANSMIT_SUPPORTED" == "1" && -n "$XDP_CORES" ]]; then
        _cfg_validate_type cores "$XDP_CORES"                     || bad+=" XDP_CORES"
    fi
    if [[ -n "$bad" ]]; then
        warn "validator.sh render: refusing to generate — invalid value(s):${bad}"
        return 1
    fi
    return 0
}

_vcfg_render_validator_sh() {
    _vcfg_assert_render_safe || return 1            # X1: validate BEFORE building the heredoc
    local e k entry_lines="" known_lines="" jito_lines="" exec_lines="" shred_line retransmit_section="" b
    # Every interpolated value is double-quoted in the EMITTED script (X1). Type
    # validation already guarantees a safe charset, so quoting cannot change
    # agave's parsing — it only removes the shell-breakout surface. Constants are
    # quoted too (cheap defense in depth). Fixed literals (program-id, when-newest,
    # numeric retain counts) are NOT interpolated and stay bare.
    for e in "${MAINNET_ENTRYPOINTS[@]}";      do entry_lines+="  --entrypoint \"${e}\""$'\n'; done
    for k in "${MAINNET_KNOWN_VALIDATORS[@]}"; do known_lines+="  --known-validator \"${k}\""$'\n'; done
    known_lines="${known_lines%$'\n'}"   # strip trailing newline HERE (ANSI-C quoting isn't honored inside a heredoc)

    if [[ "${DZ_ENABLED_RESOLVED:-false}" == "true" ]]; then
        # DZ enabled -> append the DZ multicast shred address (harmless before the
        # tunnel is up: no route to it until 'connect multicast', so it just drops).
        shred_line="  --shred-receiver-address \"${SHRED_RECEIVER_ADDRESS}\" \"${DZ_MULTICAST_SHRED}\""
    else
        shred_line="  --shred-receiver-address \"${SHRED_RECEIVER_ADDRESS}\""
    fi

    if [[ "$MEV_MODE" == "relayer" ]]; then
        jito_lines="  --relayer-url \"${RELAYER_URL}\""$'\n'
    else
        jito_lines="  --bam-url \"${BAM_URL}\""$'\n'
    fi
    jito_lines+="  --tip-payment-program-pubkey \"${JITO_TIP_PAYMENT_PROGRAM}\""$'\n'
    jito_lines+="  --tip-distribution-program-pubkey \"${JITO_TIP_DISTRIBUTION_PROGRAM}\""$'\n'
    jito_lines+="  --merkle-root-upload-authority \"${JITO_MERKLE_ROOT_AUTHORITY}\""$'\n'
    jito_lines+="  --commission-bps \"${COMMISSION_BPS}\""$'\n'
    jito_lines+="  --block-engine-url \"${BLOCK_ENGINE_URL}\""$'\n'
    jito_lines+="${shred_line}"$'\n'
    jito_lines+="  --account-index program-id"$'\n'
    jito_lines+="  --account-index-include-key \"${ALT_PROGRAM_KEY}\""

    # RETRANSMIT is ALWAYS emitted — the block states the XDP decision out loud,
    # either way. Agave 4.2.0 inverted the default: XDP used to be opt-in (no
    # flags = off), and is now opt-OUT (no flags = ON, with an auto-detected
    # interface and an auto-selected core). So "say nothing" no longer means
    # "disabled" — on a box where DeePloy decided against XDP, silence would
    # silently enable it. Two distinct paths reach that decision and both must
    # end in --no-xdp: an ineligible/unknown NIC (RETRANSMIT_SUPPORTED=0), and
    # an eligible NIC where the operator reserved no cores in phase 2
    # (XDP_CORES empty). cpu-cores first, then zero-copy (mlx5 only; bnxt is
    # non-ZC) — the prod block's order.
    local include_retransmit=0
    [[ "$RETRANSMIT_SUPPORTED" == "1" && -n "$XDP_CORES" ]] && include_retransmit=1
    retransmit_section="RETRANSMIT=("$'\n'
    if (( include_retransmit )); then
        retransmit_section+="  --xdp-cpu-cores \"${XDP_CORES}\""$'\n'
        [[ "$RETRANSMIT_ZERO_COPY" == "1" ]] && retransmit_section+="  --xdp-zero-copy"$'\n'
    else
        retransmit_section+="  --no-xdp"$'\n'
    fi
    retransmit_section+=")"$'\n'

    local blocks=(CONSENSUS GOSSIP RPC REPLAY POH RETRANSMIT)
    blocks+=(LEDGER SNAPSHOTS LOG REPORTING JITO)
    exec_lines="exec agave-validator"
    for b in "${blocks[@]}"; do exec_lines+=" \\"$'\n'"  \"\${${b}[@]}\""; done

    cat <<EOF
#!/bin/bash
set -euo pipefail
# Generated by DeePloy — regenerate via: ${DEEPLOY_CMD} install --only ${VALIDATORCFG_PHASE}

KEYPAIR="${SYNC_IDENTITY}"
[[ -r "\$KEYPAIR" ]] || { echo "FATAL: keypair \$KEYPAIR not readable"; exit 1; }

CONSENSUS=(
  --identity "${SYNC_IDENTITY}"
  --vote-account "${VOTE_ACCOUNT_PUBKEY}"
  --expected-genesis-hash "${MAINNET_GENESIS_HASH}"
  --no-poh-speed-test
)

GOSSIP=(
  --gossip-port "${GOSSIP_PORT}"
${entry_lines}  --no-port-check
)

RPC=(
  --only-known-rpc
  --rpc-port "${RPC_PORT}"
  --rpc-bind-address "${RPC_BIND_ADDRESS}"
  --rpc-threads "${RPC_THREADS}"
  --dynamic-port-range "${DYNAMIC_PORT_RANGE}"
  --full-rpc-api
  --private-rpc
${known_lines}
)

REPLAY=(
  --unified-scheduler-handler-threads "${REPLAY_THREADS}"
)

POH=(
  --poh-pinned-cpu-core "${POH_CORE}"
)
${retransmit_section}
LEDGER=(
  --ledger "${LEDGER_PATH}"
  --accounts "${ACCOUNTS_PATH}"
  --limit-ledger-size "${LIMIT_LEDGER_SIZE}"
  --wal-recovery-mode skip_any_corrupted_record
)

SNAPSHOTS=(
  --snapshots "${SNAPSHOTS_PATH}"
  --minimal-snapshot-download-speed "${MIN_SNAPSHOT_DOWNLOAD_SPEED}"
  --maximum-full-snapshots-to-retain 1
  --maximum-incremental-snapshots-to-retain 1
  --full-snapshot-interval-slots "${FULL_SNAPSHOT_INTERVAL_SLOTS}"
  --incremental-snapshot-interval-slots "${INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS}"
  --snapshot-packager-niceness-adjustment 20
  --maximum-local-snapshot-age 4000
  --use-snapshot-archives-at-startup when-newest
)

LOG=(
  --log "${SOLANA_HOME}/solana.log"
)

REPORTING=(
  --no-os-network-stats-reporting
  --no-os-memory-stats-reporting
  --no-os-cpu-stats-reporting
  --no-os-disk-stats-reporting
)

JITO=(
${jito_lines}
)

${exec_lines}
EOF
}

# --- solana.service ----------------------------------------------------------
_vcfg_render_solana_service() {
    local requires=""
    [[ "$(state_get disk_layout)" == "two-nvme" ]] && \
        requires="RequiresMountsFor=${ACCOUNTS_MOUNT:-/mnt/accounts} ${LEDGER_MOUNT:-/mnt/ledger}"$'\n'
    cat <<EOF
[Unit]
Description=Solana MB node
# StartLimitIntervalSec=0 disables systemd's start-rate limiter so Restart=always
# truly always restarts: a fast-failing crash (unreadable keypair, missing dir,
# post-upgrade flag drift) must not trip the limiter into permanent-down. (R4)
StartLimitIntervalSec=0
${requires}After=network.target systemd-remount-fs.service systemd-tmpfiles-setup.service systemd-modules-load.service auditd.service

[Service]
Type=simple
Restart=always
RestartSec=1

# XDP capabilities (Agave 4.0 requirement)
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SYS_NICE
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SYS_NICE

# Limits
LimitNOFILE=2000000
LimitMEMLOCK=2000000000
LimitNICE=40
LogRateLimitIntervalSec=0

# Priority
Nice=-10
OOMScoreAdjust=-1000

# Graceful shutdown
KillSignal=SIGTERM
TimeoutStopSec=300

# Environment
Environment="SOLANA_METRICS_CONFIG=${SOLANA_METRICS_CONFIG}"
Environment="PATH=/bin:/usr/bin:${SOLANA_INSTALL_DIR}/active_release/bin"

ExecStart=${VALIDATOR_SH}
ExecStartPost=/bin/systemctl --no-block start solana-poh-pin.service

[Install]
WantedBy=multi-user.target
EOF
}

# --- logrotate ---------------------------------------------------------------
_vcfg_render_logrotate() {
    cat <<EOF
${SOLANA_HOME}/solana.log {
  rotate 1
  daily
  missingok
  postrotate
    systemctl kill -s USR1 solana.service
  endscript
}
EOF
}

# --- set_poh_affinity.sh (placeholder-substituted; no heredoc escaping) ------
_vcfg_render_set_poh_affinity() {
    local body
    body=$(cat <<'EOF'
#!/bin/bash
# Pin the PoH tick-producer thread to the isolated core. Generated by DeePloy.
agave_pid=$(pgrep -f "^agave-validator --identity")
if [ -z "$agave_pid" ]; then logger "set_affinity: agave_validator_404"; exit 1; fi
thread_pid=$(ps -T -p "$agave_pid" -o spid,comm | grep 'solPohTickProd' | awk '{print $1}')
if [ -z "$thread_pid" ]; then logger "set_affinity: solPohTickProd_404"; exit 1; fi
current_affinity=$(taskset -cp "$thread_pid" 2>&1 | awk '{print $NF}')
if [ "$current_affinity" == "__POH_CORE__" ]; then
    logger "set_affinity: solPohTickProd_already_set"; exit 0
else
    taskset -cp __POH_CORE__ "$thread_pid"; rc=$?
    if [ "$rc" -eq 0 ]; then
        logger "set_affinity: set_done"
    else
        logger "set_affinity: taskset_failed (exit $rc)"; exit "$rc"
    fi
fi
EOF
)
    printf '%s\n' "${body//__POH_CORE__/$POH_CORE}"
}

# --- wait_and_pin_poh.sh -----------------------------------------------------
_vcfg_render_wait_and_pin() {
    local body
    body=$(cat <<'EOF'
#!/bin/bash
# Wait for the validator to catch up, then pin PoH. Generated by DeePloy.
set -uo pipefail
SOLANA_BIN="__SOLANA_BIN__"
PIN_SCRIPT="__PIN_SCRIPT__"
MAX_WAIT_SECONDS=3600
CHECK_INTERVAL=15
log() { logger -t wait_and_pin_poh "$1"; echo "[$(date -Is)] $1"; }
log "Waiting for validator to catch up to cluster..."
start_ts=$(date +%s)
while true; do
    now_ts=$(date +%s); elapsed=$((now_ts - start_ts))
    if (( elapsed > MAX_WAIT_SECONDS )); then log "FATAL: timeout after ${MAX_WAIT_SECONDS}s"; exit 1; fi
    if ! systemctl is-active --quiet solana; then log "solana.service not active, exiting"; exit 1; fi
    output=$("$SOLANA_BIN/solana" catchup --our-localhost 2>&1 | head -1)
    if echo "$output" | grep -qE "has caught up|^0 slot\(s\) behind"; then log "Caught up: $output"; break; fi
    log "Not caught up yet (elapsed ${elapsed}s): $output"
    sleep "$CHECK_INTERVAL"
done
log "Pinning PoH thread..."
bash "$PIN_SCRIPT"; pin_rc=$?
log "PoH pin completed (exit $pin_rc)"
exit "$pin_rc"
EOF
)
    body="${body//__SOLANA_BIN__/$SOLANA_INSTALL_DIR/active_release/bin}"
    body="${body//__PIN_SCRIPT__/$SET_POH_SCRIPT}"
    printf '%s\n' "$body"
}

_vcfg_render_poh_pin_service() {
    cat <<EOF
[Unit]
Description=Pin Solana PoH thread to isolated CPU core (after catchup)
After=solana.service
# Requisite, not Requires: if solana.service is not already active, FAIL this
# oneshot instead of pulling the validator up (post-boot timer / manual stop). I3
Requisite=solana.service

[Service]
Type=oneshot
ExecStart=${WAIT_PIN_SCRIPT}
TimeoutStartSec=3700
EOF
}

_vcfg_render_poh_pin_timer() {
    cat <<'EOF'
[Unit]
Description=Schedule PoH pin after validator startup

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h
Unit=solana-poh-pin.service

[Install]
WantedBy=timers.target
EOF
}

# --- generate ----------------------------------------------------------------
validatorcfg_generate() {
    step "Generating validator.sh + solana.service + poh-pin + logrotate"
    # Render validator.sh into a variable first so the X1 fail-closed gate (a
    # non-zero return from _vcfg_render_validator_sh) ABORTS here — a command
    # substitution's failure does not propagate to the enclosing write_file, so
    # without this an unvalidated value would silently produce an empty script.
    local _vsh
    _vsh="$(_vcfg_render_validator_sh)" || fail "validator.sh render aborted — an untrusted value failed type validation; refusing to write an executable validator script"
    write_file "$VALIDATOR_SH"    "$_vsh"                                0755
    write_file "$SOLANA_SERVICE"  "$(_vcfg_render_solana_service)"
    write_file "$SET_POH_SCRIPT"  "$(_vcfg_render_set_poh_affinity)"    0755
    write_file "$WAIT_PIN_SCRIPT" "$(_vcfg_render_wait_and_pin)"        0755
    write_file "$LOGROTATE_FILE"  "$(_vcfg_render_logrotate)"
    write_file "$POH_PIN_SERVICE" "$(_vcfg_render_poh_pin_service)"
    write_file "$POH_PIN_TIMER"   "$(_vcfg_render_poh_pin_timer)"

    # solana.service is written DIRECTLY to /etc/systemd/system as a real file
    # (see SOLANA_SERVICE) — no on-mount symlink, so it is readable at early boot
    # before the data mounts come up (H1). Enablement (idempotent); skipped under
    # --dry-run via run().
    run systemctl daemon-reload
    run systemctl enable solana-poh-pin.timer

    # bash -n the generated runtime scripts.
    if ! is_dry_run; then
        bash -n "$VALIDATOR_SH"    || fail "Generated validator.sh has a syntax error"
        bash -n "$SET_POH_SCRIPT"  || fail "Generated set_poh_affinity.sh has a syntax error"
        bash -n "$WAIT_PIN_SCRIPT" || fail "Generated wait_and_pin_poh.sh has a syntax error"
        ok "Generated scripts pass bash -n"
    fi
}

# --- orchestrator ------------------------------------------------------------
validatorcfg_run() {
    require_root
    validatorcfg_resolve_config
    validatorcfg_generate
}
