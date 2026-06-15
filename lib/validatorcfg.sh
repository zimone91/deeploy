#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/validatorcfg.sh   (Phase 6: validator config)
# Generates the runtime artifacts from state/config:
#   validator.sh (labeled arg-arrays), solana.service (XDP caps, Nice,
#   OOMScoreAdjust, ExecStartPost->poh-pin), logrotate, set_poh_affinity.sh,
#   wait_and_pin_poh.sh, and the solana-poh-pin service+timer.
#
# POH_CORE flows in from state (single source of truth -> both the
# --experimental-poh-pinned-cpu-core arg AND set_poh_affinity.sh). RETRANSMIT is
# emitted only when the NIC is XDP-eligible AND XDP cores were reserved. JITO is
# BAM by default (commission-bps tied to mode); the DZ multicast shred is
# appended as a 2nd --shred-receiver-address when enabled.
#
# Requires: common.sh + constants.sh sourced. Output paths are overridable for
# tests; everything goes through write_file (dry-run safe, backed up).
# ============================================================================

[[ -n "${_DEEPLOY_VALIDATORCFG_SOURCED:-}" ]] && return 0
_DEEPLOY_VALIDATORCFG_SOURCED=1

SOLANA_INSTALL_DIR="${SOLANA_INSTALL_DIR:-$HOME/.local/share/solana/install}"

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
    # commission-bps: mode-derived DEFAULT (bam->0, relayer->1000) but PROMPTED
    # at install so the operator can override — never set silently (0 is required
    # by many pools, but some want otherwise).
    local commission_default=0
    [[ "$MEV_MODE" == "relayer" ]] && commission_default=1000
    if [[ -z "${COMMISSION_BPS:-}" ]]; then
        ask "Validator MEV commission in bps (0 is required by many pools)" "$commission_default"
        COMMISSION_BPS="$REPLY"
    fi
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
_vcfg_render_validator_sh() {
    local e k entry_lines="" known_lines="" jito_lines="" exec_lines="" shred_line retransmit_section="" b
    for e in "${MAINNET_ENTRYPOINTS[@]}";      do entry_lines+="  --entrypoint ${e}"$'\n'; done
    for k in "${MAINNET_KNOWN_VALIDATORS[@]}"; do known_lines+="  --known-validator ${k}"$'\n'; done
    known_lines="${known_lines%$'\n'}"   # strip trailing newline HERE (ANSI-C quoting isn't honored inside a heredoc)

    if [[ "${DZ_ENABLED_RESOLVED:-false}" == "true" ]]; then
        # DZ enabled -> append the DZ multicast shred address (harmless before the
        # tunnel is up: no route to it until 'connect multicast', so it just drops).
        shred_line="  --shred-receiver-address ${SHRED_RECEIVER_ADDRESS} ${DZ_MULTICAST_SHRED}"
    else
        shred_line="  --shred-receiver-address ${SHRED_RECEIVER_ADDRESS}"
    fi

    if [[ "$MEV_MODE" == "relayer" ]]; then
        jito_lines="  --relayer-url ${RELAYER_URL}"$'\n'
    else
        jito_lines="  --bam-url ${BAM_URL}"$'\n'
    fi
    jito_lines+="  --tip-payment-program-pubkey ${JITO_TIP_PAYMENT_PROGRAM}"$'\n'
    jito_lines+="  --tip-distribution-program-pubkey ${JITO_TIP_DISTRIBUTION_PROGRAM}"$'\n'
    jito_lines+="  --merkle-root-upload-authority ${JITO_MERKLE_ROOT_AUTHORITY}"$'\n'
    jito_lines+="  --commission-bps ${COMMISSION_BPS}"$'\n'
    jito_lines+="  --block-engine-url ${BLOCK_ENGINE_URL}"$'\n'
    jito_lines+="${shred_line}"$'\n'
    jito_lines+="  --account-index program-id"$'\n'
    jito_lines+="  --account-index-include-key ${ALT_PROGRAM_KEY}"

    # RETRANSMIT only when the driver supports XDP retransmit AND cores were
    # reserved. cpu-cores first, then the zero-copy flag (mlx5 only; bnxt is
    # non-ZC). Matches the prod RETRANSMIT block exactly.
    local include_retransmit=0
    [[ "$RETRANSMIT_SUPPORTED" == "1" && -n "$XDP_CORES" ]] && include_retransmit=1
    if (( include_retransmit )); then
        retransmit_section="RETRANSMIT=("$'\n'"  --experimental-retransmit-xdp-cpu-cores ${XDP_CORES}"$'\n'
        [[ "$RETRANSMIT_ZERO_COPY" == "1" ]] && retransmit_section+="  --experimental-retransmit-xdp-zero-copy"$'\n'
        retransmit_section+=")"$'\n'
    fi

    local blocks=(CONSENSUS GOSSIP RPC REPLAY POH)
    (( include_retransmit )) && blocks+=(RETRANSMIT)
    blocks+=(LEDGER SNAPSHOTS LOG REPORTING JITO)
    exec_lines="exec agave-validator"
    for b in "${blocks[@]}"; do exec_lines+=" \\"$'\n'"  \"\${${b}[@]}\""; done

    cat <<EOF
#!/bin/bash
set -euo pipefail
# Generated by DeePloy — regenerate via: deeploy install --only validatorcfg

KEYPAIR=${SYNC_IDENTITY}
[[ -r "\$KEYPAIR" ]] || { echo "FATAL: keypair \$KEYPAIR not readable"; exit 1; }

CONSENSUS=(
  --identity ${SYNC_IDENTITY}
  --vote-account ${VOTE_ACCOUNT_PUBKEY}
  --expected-genesis-hash ${MAINNET_GENESIS_HASH}
  --no-poh-speed-test
)

GOSSIP=(
  --gossip-port ${GOSSIP_PORT}
${entry_lines}  --no-port-check
)

RPC=(
  --only-known-rpc
  --rpc-port ${RPC_PORT}
  --rpc-bind-address ${RPC_BIND_ADDRESS}
  --rpc-threads ${RPC_THREADS}
  --dynamic-port-range ${DYNAMIC_PORT_RANGE}
  --full-rpc-api
  --private-rpc
${known_lines}
)

REPLAY=(
  --unified-scheduler-handler-threads ${REPLAY_THREADS}
)

POH=(
  --experimental-poh-pinned-cpu-core ${POH_CORE}
)
${retransmit_section}
LEDGER=(
  --ledger ${LEDGER_PATH}
  --accounts ${ACCOUNTS_PATH}
  --limit-ledger-size ${LIMIT_LEDGER_SIZE}
  --wal-recovery-mode skip_any_corrupted_record
)

SNAPSHOTS=(
  --snapshots ${SNAPSHOTS_PATH}
  --minimal-snapshot-download-speed ${MIN_SNAPSHOT_DOWNLOAD_SPEED}
  --maximum-full-snapshots-to-retain 1
  --maximum-incremental-snapshots-to-retain 1
  --full-snapshot-interval-slots ${FULL_SNAPSHOT_INTERVAL_SLOTS}
  --incremental-snapshot-interval-slots ${INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS}
  --snapshot-packager-niceness-adjustment 20
  --maximum-local-snapshot-age 4000
  --use-snapshot-archives-at-startup when-newest
)

LOG=(
  --log ${SOLANA_HOME}/solana.log
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
StartLimitIntervalSec=5
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
    write_file "$VALIDATOR_SH"    "$(_vcfg_render_validator_sh)"        0755
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
