#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/upgrade.sh   (deeploy upgrade [--rollback])
# Rebuild to a new jito-solana tag and restart. The dangerous part is that a
# rebuild+restart of a STAKED node skips leader slots, so:
#   * list BOTH release APIs (jito-solana + agave, the latter for reference);
#     operator picks/confirms a jito-solana TAG (default = current — never
#     auto-jumps to latest); a tag not shaped like one — a bare Agave v4.3.0
#     included — is refused before anything is built;
#   * ask the node which identity it RUNS on — getIdentity on the local RPC,
#     because set-identity changes it at runtime and argv always shows the sync
#     identity — before the build AND right before every restart, --rollback
#     included: the sync identity -> proceed; anything else (staked, unknown,
#     no answer while the process is up) -> warn + require explicit "yes"
#     (prefer the failover path); not running -> proceed;
#   * rebuild via the SAME toolchain functions (identical --release-with-lto
#     --no-build-platform-tools / RUSTFLAGS / 5-cap setcap — no flag drift),
#     overlay-aware (vanilla unless private patch applies);
#   * keep the previous release (toolchain_install_release never wipes
#     releases/*), so rollback is one symlink flip.
#
# Requires: common.sh + constants.sh + toolchain.sh sourced. Probes mockable.
# ============================================================================

[[ -n "${_DEEPLOY_UPGRADE_SOURCED:-}" ]] && return 0
_DEEPLOY_UPGRADE_SOURCED=1

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
    # The agave list above is shown for reference only: its tags can clear the
    # floor on their numbers, and the jito-solana repo carries some of them
    # (v4.3.0 among them).
    deeploy_tag_agave_base "$UPGRADE_TAG" >/dev/null \
        || fail "refusing to upgrade to '${UPGRADE_TAG}': it is not a jito-solana version tag (expected vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N], e.g. v4.3.0-jito.0). Pick from the jito-solana list; the agave tags are shown for reference."
    # Same floor as the install path (constants.sh): upgrading DOWN to a client
    # that predates --no-xdp / --poh-pinned-cpu-core would rebuild fine and then
    # fail to start against the validator.sh already on the box.
    local why
    why="$(deeploy_tag_floor_problem "$UPGRADE_TAG")" \
        || fail "refusing to upgrade to '${UPGRADE_TAG}': ${why}. The validator.sh on this box passes --no-xdp and --poh-pinned-cpu-core, which only exist from ${DEEPLOY_MIN_JITO_TAG} on. Choose ${DEEPLOY_MIN_JITO_TAG} or newer."
}

# --- live-identity guard -----------------------------------------------------
# The running identity comes from the node itself: getIdentity on the local RPC
# (deeploy_live_identity, common.sh — verify uses the same probe). Fail-closed:
# anything but the sync identity — the staked key, an unknown key, no answer, an
# unparsable answer — goes through require_yes.
_upgrade_validator_running() { pgrep -f '^agave-validator --identity' >/dev/null 2>&1; }   # if-condition only

upgrade_identity_guard() {      # <when> — runs before the build and before every restart
    local when=${1:-"before the restart"} live sync
    step "Identity check ${when}"
    STAKED_RESTART=0
    live=$(deeploy_live_identity)           # the node first; pgrep only when it does not answer
    if [[ -z "$live" ]] && ! _upgrade_validator_running; then
        info "Validator not running (no answer from getIdentity, no process) — no staked-restart risk"
        return 0
    fi
    sync=$(deeploy_sync_pubkey)
    if [[ -n "$live" ]]; then
        if [[ -n "$sync" && "$live" == "$sync" ]]; then
            ok "Validator running on the sync identity (${live}, from getIdentity) — safe to restart"
            return 0
        fi
        warn "The validator is running on ${live} (getIdentity), not on the sync identity ${sync:-(sync pubkey unreadable)}."
        warn "That is the staked key or an unknown one. A restart brings the node back on the sync identity: it stops voting and skips its leader slots."
    else
        warn "The validator process is up, but its identity is unknown: getIdentity on the local RPC did not answer or could not be parsed."
    fi
    warn "Safer: use the failover tool (swap to standby, upgrade this box, swap back)."
    if ! require_yes "Proceed anyway and restart this validator?"; then
        fail "Upgrade aborted — validator left running. Use the failover path."
    fi
    STAKED_RESTART=1
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
    upgrade_identity_guard "right before the restart"   # re-read: the build is long; the identity can change meanwhile
    step "Restarting solana.service on ${JITO_TAG}"
    [[ "${STAKED_RESTART:-0}" == "1" ]] && warn "Restarting a validator that is not on the sync identity — expect a brief skipped-leader-slot window."
    run systemctl restart solana
    ok "Upgraded to ${JITO_TAG}."
    local prev; prev=$(state_get previous_release "")
    [[ -n "$prev" ]] && info "Previous release kept: ${prev}  (rollback: deeploy.sh upgrade --rollback)"
}

# --- rollback (one symlink flip) ---------------------------------------------
upgrade_rollback() {
    local prev; prev=$(state_get previous_release "")
    [[ -n "$prev" && -d "$prev" ]] || fail "No previous release recorded — cannot rollback"
    upgrade_identity_guard "before the rollback restart"   # declined -> nothing flipped, nothing restarted
    step "Rolling back active_release -> ${prev}"
    run ln -sfn "$prev" "${ACTIVE_RELEASE:?}"
    run systemctl restart solana
    ok "Rolled back to ${prev} and restarted"
}

# --- orchestrator ------------------------------------------------------------
upgrade_run() {
    require_root
    # shellcheck disable=SC2034  # read by deeploy_sync_pubkey (common.sh) in the identity guard
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (identity guard reads pubkeys via solana-keygen)
    if [[ "${ROLLBACK:-0}" == "1" ]]; then upgrade_rollback; return; fi
    upgrade_check_releases
    upgrade_identity_guard "before the build"      # early exit before a long build
    upgrade_build
    upgrade_restart
}
