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
    DZ_ENABLED="$(state_get dz_enabled false)"   # was dz_multicast (latent bug): the finalize pointer keys on ENABLEMENT
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

# Is solana.service already up with a live validator process? (mockable probe)
# Uses pgrep (not `solana catchup`) because during a snapshot download the RPC
# isn't serving yet, but the agave-validator process IS running and downloading —
# restarting it there throws away snapshot progress. systemd `active` + a live
# process is the right "healthy/making-progress" signal at this stage.
# The pattern is ANCHORED ('^agave-validator --identity') to match the codebase
# convention (validatorcfg/verify/upgrade) — that is exactly the real validator's
# argv (validator.sh execs `agave-validator --identity …`), so it still matches a
# node mid-snapshot, while not adopting on an unrelated substring match.
_start_solana_running() {
    systemctl is-active --quiet solana 2>/dev/null || return 1
    pgrep -f '^agave-validator --identity' >/dev/null 2>&1
}

start_enable_service() {
    step "Enabling solana.service"
    # The unit is a real file at /etc/systemd/system/solana.service (written in
    # Phase 6) — enable it by name; no on-mount symlink to (re)create here (H1).
    run systemctl daemon-reload
    run systemctl enable solana
    # IDEMPOTENT start — "ensure running", NOT "restart". Two paths reach Phase 8
    # (the post-reboot resume service AND a manual `install --resume`); an
    # unconditional restart of an already-running node mid-snapshot-download
    # restarts the download from 0%. So adopt an already-running node instead.
    if _start_solana_running; then
        ok "solana.service already running (adopting it — NOT restarting; snapshot/catchup progress preserved)"
        return 0
    fi
    step "Starting solana.service"
    run systemctl start solana
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
    # Non-fatal: the node is already up + synced here, and set_poh_affinity now
    # reports a real failure (H4) instead of swallowing it — a pin failure must not
    # abort the run; the hourly poh-pin timer retries.
    run bash "$SET_POH_SCRIPT" || warn "PoH pin did not succeed — the poh-pin timer will retry (check 'systemctl status solana-poh-pin')"
}

start_print_summary() {
    local catchup_rc="${1:-0}" verify_rc="${2:-0}"
    # Degraded/failed finish: the node never reached catchup 0 (timed out or the
    # service died). Say so plainly and tell the operator NOT to swap the staked
    # key — a staked identity must only go live on a synced node (R1).
    if [[ "$catchup_rc" -ne 0 ]]; then
        step "DEPLOYMENT INCOMPLETE — node NOT synced"
        warn "The node did not reach catchup 0 (catchup timed out or solana.service is not active)."
        info "  DO NOT swap in the staked key — a staked identity must only go live on a synced node."
        info "  Check:   systemctl status solana   and   journalctl -u solana -e"
        info "  Resume:  ${DEEPLOY_CMD} install --resume   (re-attempts catchup; a running node is adopted, not restarted)"
        info ""
        info "Vote account: ${VOTE_ACCOUNT_PUBKEY:-<unset>}"
        return 0
    fi
    step "DEPLOYMENT COMPLETE"
    ok "Node is synced (catchup 0) on the unstaked sync identity."
    [[ "$verify_rc" -ne 0 ]] && warn "Post-install verification reported issues — review them above and run '${DEEPLOY_CMD} verify' before the staked-key swap."
    info ""
    info "MANUAL staked-key hot-swap (DeePloy never touches the real key):"
    info "  1) Place the real staked keypair at:  ${STAKED_KEYPAIR}   (chmod 600)"
    info "  2) Swap identity (path-as-argument form):"
    info "       ${SOLANA_BIN}/agave-validator --ledger ${LEDGER_PATH} set-identity ${STAKED_KEYPAIR}"
    info "       ${SOLANA_BIN}/agave-validator --ledger ${LEDGER_PATH} authorized-voter add ${STAKED_KEYPAIR}"
    info "     No tower transfer needed: a fresh node rebuilds its vote floor from the cluster."
    info ""
    [[ "$DZ_ENABLED" == "true" ]] && info "DoubleZero: after the swap, run  ${DEEPLOY_CMD} dz-connect  (passport + ibrl + multicast)."
    info ""
    info "Failover is a SEPARATE tool (not bundled): install it later via its own one-line"
    info "installer; DeePloy's exported config (${DEEPLOY_CMD} export) is reusable by it."
    info ""
    info "Vote account: ${VOTE_ACCOUNT_PUBKEY:-<unset>}"
}

start_run() {
    require_root
    # Universal CPU-isolation gate: EVERY route to start — the post-reboot resume,
    # a manual --resume, AND `install --only 8` (which bypasses the reboot boundary)
    # — must confirm the recorded isolation is actually live before launching the
    # validator (PoH on a non-isolated core skips slots). This closes the --only 8
    # bypass (I2) and backstops a stale reboot_done latch (I1). Guarded: defined in
    # deeploy.sh, so it no-ops when start.sh is unit-tested standalone.
    if declare -F _install_verify_isolation >/dev/null 2>&1; then
        _install_verify_isolation || fail "CPU isolation not verified — refusing to start the validator. Fix GRUB and re-run (see the diagnostics above)."
    fi
    start_resolve_config
    start_precheck_disk
    start_enable_service
    # Capture the catchup + verify results (don't swallow them) so the summary can
    # tell a real success from a degraded/failed finish, and Phase 8 isn't marked a
    # clean success when the node never synced (R1).
    local catchup_rc=0 verify_rc=0
    start_wait_catchup || catchup_rc=$?
    [[ $catchup_rc -eq 0 ]] || warn "catchup did not complete (timed out, or solana.service is not active)"
    start_pin_poh
    if declare -F verify_run >/dev/null 2>&1; then verify_run || verify_rc=$?; else info "verify.sh not loaded — skipping verification"; fi
    start_print_summary "$catchup_rc" "$verify_rc"
    # An unsynced node is NOT a clean Phase 8: return non-zero so run_phase does not
    # mark phase 8 done and an idempotent resume re-attempts catchup (the running
    # node is adopted, not restarted). A verify-only failure is advisory (the node
    # IS synced) — surfaced in the summary, but it does not fail the phase.
    [[ $catchup_rc -eq 0 ]] || return 1
    return 0
}
