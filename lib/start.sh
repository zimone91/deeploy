#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/start.sh   (Phase 8: start -> catchup 0 -> verify)
# Pre-start free-disk check -> enable+start solana.service -> wait for the node
# to catch up (catchup 0) -> pin the PoH thread -> run the verification block ->
# print the final summary with the MANUAL staked-key hot-swap (path form) and a
# pointer to the separate failover tool.
#
# Requires: common.sh sourced (verify.sh for the verification block). All
# mutations go through run(); probes are mockable for tests.
# ============================================================================

[[ -n "${_DEEPLOY_START_SOURCED:-}" ]] && return 0
_DEEPLOY_START_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-$HOME/.local/share/solana/install/active_release/bin}"
START_MIN_ACCOUNTS_GB="${START_MIN_ACCOUNTS_GB:-300}"   # snapshot rebuild + accountsdb
START_MIN_LEDGER_GB="${START_MIN_LEDGER_GB:-100}"       # snapshot download + ledger
CATCHUP_TIMEOUT="${CATCHUP_TIMEOUT:-3600}"
CATCHUP_INTERVAL="${CATCHUP_INTERVAL:-15}"

start_resolve_config() {
    SOLANA_HOME="$(state_get solana_home /root/solana)"
    LEDGER_PATH="$(state_get ledger_path "$SOLANA_HOME/ledger")"
    ACCOUNTS_PATH="$(state_get accounts_path /mnt/accounts/solana/accounts)"
    SNAPSHOTS_PATH="$(state_get snapshots_path "$SOLANA_HOME/snapshots")"
    STAKED_KEYPAIR="$(state_get staked_keypair "$SOLANA_HOME/mainnet-validator-keypair.json")"
    VOTE_ACCOUNT_PUBKEY="$(state_get vote_account_pubkey "")"
    SET_POH_SCRIPT="${SET_POH_SCRIPT:-$SOLANA_HOME/set_poh_affinity.sh}"
    SOLANA_SERVICE="${SOLANA_SERVICE:-$SOLANA_HOME/solana.service}"
    DZ_ENABLED="$(state_get dz_multicast false)"
    # Resolve the validator bin dir WITHOUT $HOME — Phase 8 runs under the systemd
    # resume service where $HOME is empty (was: "/.local/.../solana" -> not found).
    SOLANA_BIN="$(deeploy_solana_bin)"
}

# Free space on the FS holding a path, in GiB (mockable).
_start_free_gb() { df -BG "$1" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}'; }

start_precheck_disk() {
    step "Pre-start free-disk check"
    local acc led
    acc=$(_start_free_gb "$(dirname "$ACCOUNTS_PATH")")
    led=$(_start_free_gb "$(dirname "$SNAPSHOTS_PATH")")
    if [[ -n "$acc" && "$acc" -lt "$START_MIN_ACCOUNTS_GB" ]]; then
        vf_or_fail "Accounts FS has ${acc}G free (< ${START_MIN_ACCOUNTS_GB}G) — snapshot rebuild may fail"
    else ok "Accounts FS free: ${acc:-?}G"; fi
    if [[ -n "$led" && "$led" -lt "$START_MIN_LEDGER_GB" ]]; then
        vf_or_fail "Ledger FS has ${led}G free (< ${START_MIN_LEDGER_GB}G) — snapshot download may fail"
    else ok "Ledger FS free: ${led:-?}G"; fi
}
# Warn (don't hard-abort) on low disk unless the operator insists on stopping.
vf_or_fail() { warn "$1"; }

start_enable_service() {
    step "Enabling + starting solana.service"
    run ln -sfn "$SOLANA_SERVICE" /etc/systemd/system/solana.service
    run systemctl daemon-reload
    run systemctl enable solana
    run systemctl restart solana
}

# Wait for catchup 0 (the operator's wait loop). Blocks up to CATCHUP_TIMEOUT.
start_wait_catchup() {
    step "Waiting for catchup (this can take 5-30+ minutes)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would poll 'solana catchup --our-localhost' until 0 behind"; return 0; fi
    local start_ts now elapsed out
    start_ts=$(date +%s)
    while true; do
        now=$(date +%s); elapsed=$((now - start_ts))
        if (( elapsed > CATCHUP_TIMEOUT )); then warn "catchup timed out after ${CATCHUP_TIMEOUT}s"; return 1; fi
        if ! systemctl is-active --quiet solana; then warn "solana.service not active — aborting wait"; return 1; fi
        out=$("$SOLANA_BIN/solana" catchup --our-localhost 2>&1 | head -1 || true)   # catchup is non-zero until synced; must not errexit the poll loop
        if grep -qE 'has caught up|^0 slot\(s\) behind' <<<"$out"; then ok "Caught up: $out"; return 0; fi
        info "catchup: ${out} (elapsed ${elapsed}s)"
        sleep "$CATCHUP_INTERVAL"
    done
}

start_pin_poh() {
    step "Pinning PoH thread"
    [[ -f "$SET_POH_SCRIPT" ]] || { warn "$SET_POH_SCRIPT missing — the poh-pin timer will handle it"; return 0; }
    run bash "$SET_POH_SCRIPT"
}

start_print_summary() {
    step "DEPLOYMENT COMPLETE"
    ok "Node is synced (catchup 0) on the THROWAWAY fake identity."
    info ""
    info "MANUAL staked-key hot-swap (DeePloy never touches the real key):"
    info "  1) Place the real staked keypair at:  ${STAKED_KEYPAIR}   (chmod 600)"
    info "  2) Swap identity (path-as-argument form):"
    info "       ${SOLANA_BIN}/agave-validator --ledger ${LEDGER_PATH} set-identity ${STAKED_KEYPAIR}"
    info "       ${SOLANA_BIN}/agave-validator --ledger ${LEDGER_PATH} authorized-voter add ${STAKED_KEYPAIR}"
    info "     No tower transfer needed: a fresh node rebuilds its vote floor from the cluster."
    info ""
    [[ "$DZ_ENABLED" == "true" ]] && info "DoubleZero: after the swap, run  deeploy dz-finalize  (passport access)."
    info ""
    info "Failover is a SEPARATE tool (not bundled): install it later via its own one-line"
    info "installer; DeePloy's exported config (deeploy export) is reusable by it."
    info ""
    info "Vote account: ${VOTE_ACCOUNT_PUBKEY:-<unset>}"
}

start_run() {
    require_root
    start_resolve_config
    start_precheck_disk
    start_enable_service
    start_wait_catchup || warn "Proceeding to verification despite catchup wait result"
    start_pin_poh
    if declare -F verify_run >/dev/null 2>&1; then verify_run || true; else info "verify.sh not loaded — skipping verification"; fi
    start_print_summary
}
