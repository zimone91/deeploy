#!/usr/bin/env bash
# ============================================================================
# DeePloy — entrypoint / dispatcher
# Subcommands: install | upgrade | verify | export | import | dz-connect
# The load-bearing part is the phased install with a reboot-resume across the
# CPU-isolation reboot. See install_run() and _install_reboot_boundary().
#
# Source-safe: defining functions has no side effects; main() (which sets
# `set -Eeuo pipefail`) runs only when the file is executed, so tests can source
# this file and drive the dispatch logic directly.
# ============================================================================

DEEPLOY_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DEEPLOY_DIR="$(dirname "$DEEPLOY_SELF")"
LIB="${DEEPLOY_LIB_DIR:-$DEEPLOY_DIR/lib}"

# shellcheck source=lib/common.sh
source "$LIB/common.sh"
for _m in constants region preflight base tuning disk toolchain keys validatorcfg nic doublezero start verify config upgrade; do
    # shellcheck disable=SC1090
    source "$LIB/${_m}.sh"
done
unset _m

RESUME_SERVICE_NAME="deeploy-resume.service"
RESUME_SERVICE_FILE="${RESUME_SERVICE_FILE:-/etc/systemd/system/${RESUME_SERVICE_NAME}}"

# Ordered install phases.
DEEPLOY_PHASES=(0 1 2 3 4 5 6 7 8)
phase_name() {
    case "$1" in
        0) echo "Preflight" ;; 1) echo "Base" ;; 2) echo "Tuning" ;; 3) echo "Disk" ;;
        4) echo "Toolchain" ;; 5) echo "Keys" ;; 6) echo "ValidatorConfig" ;;
        7) echo "DoubleZero" ;; 8) echo "Start" ;; *) echo "?" ;;
    esac
}
# Phases 0-7 are interactive; 8 is non-interactive (safe to run unattended post-reboot).
_phase_is_interactive() { [[ "$1" -lt 8 ]]; }

run_phase() {
    local n=$1
    phase_begin "$n" "$(phase_name "$n")"
    case "$n" in
        0) preflight_run ;;
        1) base_run ;;
        2) tuning_run ;;
        3) disk_run ;;
        4) toolchain_build ;;
        5) keys_run ;;
        6) validatorcfg_run; nic_run ;;
        7) # DZ prepare (install/env/ufw) already happened in Phase 1. Phase 7 is
           # just a pointer to the manual post-swap 'deeploy dz-connect'. Enable
           # decision was made/recorded in Phase 1.
           if [[ "$(state_get dz_enabled false)" == "true" ]]; then doublezero_run
           else info "DoubleZero not enabled — skipping (answer 'y' at the Phase 1 prompt or set DZ_ENABLED=true)"; fi ;;
        8) start_run ;;
    esac
    phase_end "$n"
}

# --- reboot-resume across the CPU-isolation reboot ---------------------------
_install_read_isolated() { cat /sys/devices/system/cpu/isolated 2>/dev/null; }   # mockable
_install_read_cmdline()  { cat /proc/cmdline 2>/dev/null; }                       # mockable

# Verify GRUB CPU isolation actually took effect after the reboot. A node up
# WITHOUT isolation runs PoH on a non-isolated core (skips) — so on mismatch we
# log FAIL and refuse to start the validator.
_install_verify_isolation() {
    local want actual cmdline cmd_isol count
    want="$(state_get isolated_set "")"
    [[ -z "$want" ]] && { info "No isolated set recorded — skipping isolation verification"; return 0; }
    actual="$(_install_read_isolated)"
    if [[ "$actual" != "$want" ]]; then
        count=$(( $(state_get isolation_mismatch_count 0) + 1 ))
        state_set isolation_mismatch_count "$count"
        cmd_isol="$(grep -o 'isolcpus=[^ ]*' <<<"$(_install_read_cmdline)" || echo '<none>')"
        _log FAIL "isolation mismatch #${count}: got '${actual}' want '${want}'"
        # Immediate, concrete diagnostics so the operator isn't left wondering why
        # the node won't come up after the reboot.
        {
            printf '%s  [FAIL]%s CPU isolation NOT applied after reboot — the validator will NOT start.\n' "$C_RED" "$C_NC"
            printf '    expected isolated set : %s\n' "$want"
            printf '    actual   isolated set : %s\n' "${actual:-<none>}"
            printf '    /proc/cmdline         : %s\n' "$cmd_isol"
            printf '    Why: PoH on a non-isolated core causes skipped slots — refusing to start.\n'
            printf '    Fix:\n'
            printf '      1) inspect /etc/default/grub (GRUB_CMDLINE_LINUX_DEFAULT) and /boot/grub/grub.cfg\n'
            printf '      2) regenerate + re-apply:  %s install --only 2   (then reboot)\n' "$DEEPLOY_SELF"
            printf '         (or manually: update-grub && reboot)\n'
        } >&2
        if (( count >= 3 )); then
            warn "Reboot attempt #${count} with the SAME isolation failure — the GRUB config is broken. Stop rebooting and fix it manually (see above)."
        fi
        return 1
    fi
    cmdline="$(_install_read_cmdline)"
    grep -q "isolcpus=domain,managed_irq,${want}" <<<"$cmdline" \
        || warn "isolcpus not found in /proc/cmdline as expected (continuing — /sys isolated matched)"
    state_clear isolation_mismatch_count
    ok "CPU isolation verified after reboot (isolated=${actual})"
    return 0
}

_install_setup_resume_service() {
    write_file "$RESUME_SERVICE_FILE" \
"[Unit]
Description=DeePloy resume after reboot (verify CPU isolation, then start validator)
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# systemd starts services with an empty environment. DeePloy's later phases read
# \$HOME (active_release path) and need cargo on PATH, so set both explicitly —
# otherwise \$HOME is empty and Phase 8's catchup wait runs '/.local/.../solana'.
Environment=\"HOME=/root\"
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.cargo/bin\"
ExecStart=${DEEPLOY_SELF} install --resume --post-reboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"
    run systemctl daemon-reload
    run systemctl enable "$RESUME_SERVICE_NAME"
}

_install_disable_resume_service() {
    run systemctl disable "$RESUME_SERVICE_NAME" 2>/dev/null || true
    state_clear reboot_pending
}

# Post-reboot completion, shared by the auto-resume service AND a manual --resume
# that detects the reboot already happened. Verify CPU isolation is actually live
# (fail-closed — a node started without it runs PoH on a non-isolated core and
# skips slots), restore a CONNECTED DoubleZero tunnel, latch reboot_done.
_install_post_reboot_proceed() {
    _install_verify_isolation || fail "Isolation verification failed — not starting the validator. Fix GRUB and re-run."
    # Only the CONNECTED tunnel needs restore. DZ prepared-but-not-connected (the
    # normal pre-swap state) no-ops. Gated on dz_connected, not dz_enabled.
    if [[ "$(state_get dz_connected "")" != "" ]] && declare -F dz_resume >/dev/null 2>&1; then
        dz_resume || warn "DoubleZero post-reboot restore had issues — check 'doublezero status'"
    fi
    state_set reboot_done "$(_ts)"
    return 0
}

# Called right before phase 8. Returns 0 to proceed to phase 8, 1 to STOP
# install_run (a reboot was requested and the box must reboot first).
_install_reboot_boundary() {
    local want
    # No GRUB change, or we already came back from the reboot -> just proceed.
    if [[ "$(state_get reboot_required 0)" != "1" ]] || state_has reboot_done; then
        return 0
    fi
    want="$(state_get isolated_set "")"
    # The post-reboot resume service: verify isolation, restore DZ, latch done.
    if [[ "$POST_REBOOT" == "1" ]]; then
        _install_post_reboot_proceed
        return 0
    fi
    # A MANUAL `install --resume` after the reboot ALREADY happened (the resume
    # service died before recording reboot_done): the booted kernel already carries
    # the wanted isolation, so verify + proceed to Phase 8 instead of re-prompting a
    # second, pointless reboot (I5). Guards keep this from firing pre-reboot — a
    # not-yet-rebooted box lacks the new isolcpus in /proc/cmdline, and a sanctioned
    # re-tune clears reboot_pending (I1) — so only a genuine post-reboot manual
    # resume reaches here.
    if [[ -n "$want" ]] && state_has reboot_pending \
       && grep -q "isolcpus=domain,managed_irq,${want}" <<<"$(_install_read_cmdline)"; then
        info "CPU-isolation reboot already applied — resuming to Phase 8 (no second reboot needed)."
        _install_post_reboot_proceed
        return 0
    fi
    # Pre-reboot: install the auto-resume oneshot, then reboot.
    _install_setup_resume_service
    state_set reboot_pending "$(_ts)"
    # Early DoubleZero old-server reminder (informational) — gives the operator
    # time to disconnect DZ on the OLD server before the reboot + staked-key swap.
    # The blocking gate is later, in dz-connect.
    if [[ "$(state_get dz_enabled false)" == "true" ]] && declare -F dz_print_old_server_reminder >/dev/null 2>&1; then
        dz_print_old_server_reminder
    fi
    step "Reboot required to apply CPU isolation"
    info "All interactive setup (phases 0-7) is complete."
    info "After reboot, ${RESUME_SERVICE_NAME} auto-runs: it verifies isolation, then phase 8 (start -> catchup -> verify)."
    info "Manual alternative after reboot:  ${DEEPLOY_SELF} install --resume"
    if confirm "Reboot now?" Y; then
        ok "Rebooting now — DeePloy will resume automatically."
        run systemctl reboot
    else
        warn "Reboot skipped. The validator will NOT start until you reboot (auto-resume) or run --resume after a reboot."
    fi
    return 1
}

# --- install dispatch --------------------------------------------------------
install_run() {
    require_root
    state_set deeploy_version "$DEEPLOY_VERSION"
    local p
    for p in "${DEEPLOY_PHASES[@]}"; do
        # --only <phase>: run exactly that phase, nothing else.
        if [[ -n "${ONLY_PHASE:-}" ]]; then
            [[ "$p" == "$ONLY_PHASE" ]] && run_phase "$p"
            continue
        fi
        # Idempotent resume: skip completed phases unless --force.
        if is_phase_done "$p" && [[ "${FORCE:-0}" != "1" ]]; then
            debug "phase $p ($(phase_name "$p")) already done — skipping"
            continue
        fi
        # Unattended post-reboot must NEVER run an un-done interactive phase.
        if [[ "$POST_REBOOT" == "1" ]] && _phase_is_interactive "$p"; then
            fail "Post-reboot resume reached un-done interactive phase $p ($(phase_name "$p")). Run '${DEEPLOY_SELF} install --resume' interactively to finish phases 0-7 first."
        fi
        # Reboot gate sits between phase 7 and phase 8.
        if [[ "$p" == "8" ]]; then
            _install_reboot_boundary || return 0
        fi
        run_phase "$p"
    done
    [[ "$POST_REBOOT" == "1" ]] && _install_disable_resume_service
    ok "DeePloy install complete"
}

# --- other subcommands -------------------------------------------------------
verify_cmd()      { require_root; verify_run; }
dz_connect_cmd()  { require_root; dz_connect_run; }
upgrade_cmd()     { require_root; debug "upgrade (rollback=${ROLLBACK:-0})"; upgrade_run; }
export_cmd()      { require_root; config_export; }
import_cmd()      { require_root; debug "import (rescore=${RESCORE:-0})"; config_import; }

# --- config + args -----------------------------------------------------------
_load_config() {
    local cfg="${CONFIG_FILE:-${DEEPLOY_CONF:-/opt/deeploy/deeploy.conf}}"
    [[ -f "$cfg" ]] || return 0
    # Parse, NEVER source (S2): this runs on EVERY command, before dispatch, so a
    # poisoned conf at any of these paths must not execute as root.
    if _config_parse_safe "$cfg"; then
        debug "loaded config $cfg"
    elif [[ -n "${CONFIG_FILE:-}" || -n "${DEEPLOY_CONF:-}" ]]; then
        # Operator pointed at this file explicitly (--config / $DEEPLOY_CONF): abort.
        fail "malformed config $cfg — refusing to continue"
    else
        # Only the default path was auto-loaded: warn + apply nothing (don't brick
        # verify/recovery on a bad on-box default).
        warn "ignoring malformed config $cfg"
    fi
}

print_version() { printf 'DeePloy %s\n' "$DEEPLOY_VERSION"; }

usage() {
    cat <<USAGE
DeePloy — Solana mainnet validator deploy/tune/upgrade
Usage: deeploy.sh <command> [flags]

Commands:
  install        Phased deploy (resumable across the isolation reboot)
  upgrade        Rebuild to a new jito-solana tag (keeps previous for rollback)
  verify         Run the post-install verification block
  export|import  Write/read deeploy.conf (paths/pubkeys only)
  dz-connect     DoubleZero connect: passport + ibrl + multicast (run AFTER the manual staked-key swap)

Flags:
  --dry-run            Print the plan; change nothing
  --resume             Continue from the first un-done phase
  --only <phase>       Run a single phase (0-8)
  --force              Re-run even completed phases
  --yes                Auto-confirm normal prompts (never disk wipes)
  --config <path>      Load a deeploy.conf as defaults
  --rescore            (import) re-ping BAM/block-engine instead of reproducing the stored region
  --rollback           (upgrade) switch back to the previous release
  --post-reboot        Internal: unattended resume after the reboot
  --version, -V        Print version and exit
USAGE
}

parse_args() {
    SUBCMD="${1:-}"; shift || true
    ONLY_PHASE=""; FORCE=0; CONFIG_FILE=""; RESCORE=0; ROLLBACK=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)     DRY_RUN=1 ;;
            --resume)      : ;;   # resume == skip completed phases, which is the default
            --post-reboot) POST_REBOOT=1 ;;
            --yes|-y)      ASSUME_YES=1 ;;
            --force)       FORCE=1 ;;
            --rescore)     RESCORE=1 ;;
            --rollback)    ROLLBACK=1 ;;
            --only)        ONLY_PHASE="$2"; shift ;;
            --config)      CONFIG_FILE="$2"; shift ;;
            --version|-V)  print_version; exit 0 ;;
            -h|--help)     usage; exit 0 ;;
            *)             fail "Unknown argument: $1" ;;
        esac
        shift
    done
}

main() {
    set -Eeuo pipefail
    parse_args "$@"
    case "$SUBCMD" in --version|-V|version) print_version; exit 0 ;; esac
    common_init
    deeploy_init_traps
    _load_config
    case "$SUBCMD" in
        install)     install_run ;;
        upgrade)     upgrade_cmd ;;
        verify)      verify_cmd ;;
        export)      export_cmd ;;
        import)      import_cmd ;;
        dz-connect|dz-finalize) dz_connect_cmd ;;   # dz-finalize: back-compat alias
        ""|-h|--help) usage; exit 0 ;;
        *)           usage; fail "Unknown command: $SUBCMD" ;;
    esac
}

# Run only when executed directly (so tests can source this file).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
