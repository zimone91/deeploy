#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/upgrade.sh   (deeploy upgrade [--rollback])
# Rebuild to a new jito-solana tag and restart. The dangerous part is that a
# rebuild+restart of a STAKED node skips leader slots, so:
#   * check BOTH release APIs (jito-solana + agave); operator picks/confirms a
#     TAG (default = current — never auto-jumps to latest);
#   * detect the RUNNING identity: if staked -> warn + require explicit "yes"
#     (prefer the failover path); if unstaked/not-running -> proceed;
#   * rebuild via the SAME toolchain functions (identical --release-with-lto
#     --no-build-platform-tools / RUSTFLAGS / 5-cap setcap — no flag drift),
#     overlay-aware (vanilla unless private patch applies);
#   * keep the previous release (toolchain_install_release never wipes
#     releases/*), so rollback is one symlink flip.
#
# Requires: common.sh + toolchain.sh sourced. Network/identity probes mockable.
# ============================================================================

[[ -n "${_DEEPLOY_UPGRADE_SOURCED:-}" ]] && return 0
_DEEPLOY_UPGRADE_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-${ACTIVE_RELEASE:-$HOME/.local/share/solana/install/active_release}/bin}"
STAKED_RESTART=0

# --- release APIs (mockable) -------------------------------------------------
_upgrade_fetch_tags() {
    local repo=$1
    curl -s -m 15 "https://api.github.com/repos/${repo}/releases?per_page=15" 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' || true
}

upgrade_check_releases() {
    step "Checking releases — jito-solana + agave"
    local jito agave current
    jito=$(_upgrade_fetch_tags jito-foundation/jito-solana)
    agave=$(_upgrade_fetch_tags anza-xyz/agave)
    info "Recent jito-solana tags:"; printf '%s\n' "$jito"  | grep -v '^$' | head -8 | sed 's/^/    /'
    info "Recent agave tags:";       printf '%s\n' "$agave" | grep -v '^$' | head -5 | sed 's/^/    /'
    current=$(state_get jito_tag "")
    # Default = current tag, so a bare Enter does NOT jump to latest.
    ask "jito-solana tag to build (current: ${current:-none})" "$current"
    UPGRADE_TAG="$REPLY"
    [[ -n "$UPGRADE_TAG" ]] || fail "No tag chosen"
    [[ "$UPGRADE_TAG" == "$current" ]] && warn "Chosen tag equals current (${current}) — rebuilding the same version"
    [[ "$UPGRADE_TAG" == *-jito ]] || warn "Tag '${UPGRADE_TAG}' does not end in -jito — double-check it"
}

# --- staked-identity guard (mockable probes) ---------------------------------
_upgrade_running_identity() {
    local pid idfile
    pid=$(pgrep -f '^agave-validator --identity' 2>/dev/null | head -1 || true)
    [[ -z "$pid" ]] && return 0
    idfile=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | sed -nE 's/.*--identity[[:space:]=]+([^[:space:]]+).*/\1/p' | head -1 || true)
    [[ -n "$idfile" ]] && "$SOLANA_BIN/solana-keygen" pubkey "$idfile" 2>/dev/null
}
_upgrade_staked_pubkey() {
    local sk; sk=$(state_get staked_keypair "")
    [[ -f "$sk" ]] && "$SOLANA_BIN/solana-keygen" pubkey "$sk" 2>/dev/null
}

upgrade_identity_guard() {
    step "Identity check before rebuild/restart"
    local running staked
    running=$(_upgrade_running_identity || true)
    if [[ -z "$running" ]]; then
        info "Validator not running (or identity undetectable) — no staked-restart risk"
        return 0
    fi
    staked=$(_upgrade_staked_pubkey || true)
    if [[ -n "$staked" && "$running" == "$staked" ]]; then
        warn "The validator is running on the STAKED identity: ${running}"
        warn "Rebuilding + restarting it WILL skip leader slots during the restart."
        warn "Safer: use the failover tool (swap to standby, upgrade this box, swap back)."
        if ! require_yes "Proceed anyway and restart the STAKED validator for this upgrade?"; then
            fail "Upgrade aborted — staked node left running. Use the failover path."
        fi
        STAKED_RESTART=1
    else
        ok "Validator running on a non-staked identity (${running}) — safe to upgrade"
    fi
}

# --- rebuild (reuses toolchain functions: identical flags, no drift) ---------
upgrade_build() {
    JITO_TAG="$UPGRADE_TAG"
    state_set jito_tag "$JITO_TAG"
    step "Rebuilding jito-solana ${JITO_TAG} (same recipe as initial build)"
    toolchain_fetch_source
    toolchain_apply_overlay        # vanilla unless private/ patch applies cleanly
    toolchain_inject_lto_profile
    toolchain_patch_cargo_script
    toolchain_compile              # --release-with-lto --no-build-platform-tools + full RUSTFLAGS
    toolchain_install_release      # repoints active_release; KEEPS the previous release
    toolchain_write_threshold      # only when the overlay applied
    toolchain_setcap               # the 5 caps
    toolchain_verify
}

upgrade_restart() {
    step "Restarting solana.service on ${JITO_TAG}"
    [[ "${STAKED_RESTART:-0}" == "1" ]] && warn "Restarting a STAKED validator — expect a brief skipped-leader-slot window."
    run systemctl restart solana
    ok "Upgraded to ${JITO_TAG}."
    local prev; prev=$(state_get previous_release "")
    [[ -n "$prev" ]] && info "Previous release kept: ${prev}  (rollback: deeploy.sh upgrade --rollback)"
}

# --- rollback (one symlink flip) ---------------------------------------------
upgrade_rollback() {
    local prev; prev=$(state_get previous_release "")
    [[ -n "$prev" && -d "$prev" ]] || fail "No previous release recorded — cannot rollback"
    step "Rolling back active_release -> ${prev}"
    run ln -sfn "$prev" "${ACTIVE_RELEASE:?}"
    run systemctl restart solana
    ok "Rolled back to ${prev} and restarted"
}

# --- orchestrator ------------------------------------------------------------
upgrade_run() {
    require_root
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (identity guard reads pubkeys via solana-keygen)
    if [[ "${ROLLBACK:-0}" == "1" ]]; then upgrade_rollback; return; fi
    upgrade_check_releases
    upgrade_identity_guard
    upgrade_build
    upgrade_restart
}
