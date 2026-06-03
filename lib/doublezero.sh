#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/doublezero.sh   (DoubleZero, optional — TWO parts)
#
# DoubleZero passport requires the validator to be visible in Solana gossip AND
# in the leader schedule — which is only true AFTER the manual swap to the
# STAKED identity. The unstaked sync identity the node deploys on is NOT in
# gossip, so passport/connect cannot run during the main install. DZ therefore
# splits in two:
#
#   PART A — Phase 7 "prepare" (this runs in the main install; SAFE, no active
#     networking, never touches the staked key): install the package, set the
#     mainnet-beta env, open the firewall (GRE/BGP/44880), place the migrated
#     DoubleZero ID (with a heads-up to disconnect the OLD server later), discover
#     devices, enable on boot. Records dz_prepared=true. Does NOT connect,
#     passport, multicast, or run a local `doublezero disconnect`.
#
#   PART B — `deeploy dz-connect` (the operator runs this AFTER the manual
#     staked-key swap, Path 1): poll `passport find-validator` until the node is
#     in gossip + leader schedule, run passport (prepare/sign/request — this DOES
#     read the staked key, the one intentional exception, only here), connect
#     ibrl, poll `doublezero status` until up, then connect multicast. No
#     validator restart: the multicast shred-address is already baked into
#     validator.sh (Phase 6, gated on dz_enabled) and picked up live.
#
# The 2nd shred-receiver-address (DZ multicast, 233.84.178.1:7733) is added to
# validator.sh in Phase 6 iff dz_enabled — the SAME single "Enable DoubleZero?"
# decision that gates Part A. There is no separate multicast prompt.
#
# Requires: common.sh sourced. doublezero/doublezero-solana/solana(-keygen)/ufw/
# systemctl/curl/apt-get are mockable; paths overridable for tests.
# ============================================================================

[[ -n "${_DEEPLOY_DOUBLEZERO_SOURCED:-}" ]] && return 0
_DEEPLOY_DOUBLEZERO_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-$HOME/.local/share/solana/install/active_release/bin}"
DZ_SETUP_URL="${DZ_SETUP_URL:-https://dl.cloudsmith.io/public/malbeclabs/doublezero/setup.deb.sh}"
DZ_CONFIG_DIR="${DZ_CONFIG_DIR:-$HOME/.config/doublezero}"
DZ_OVERRIDE_CONF="${DZ_OVERRIDE_CONF:-/etc/systemd/system/doublezerod.service.d/override.conf}"
DZ_ENV="${DZ_ENV:-mainnet-beta}"
# Tunables (overridable for tests; real defaults match the docs' timings).
DZ_FIND_RETRIES="${DZ_FIND_RETRIES:-60}"      # find-validator poll: ~15 min at 15s
DZ_FIND_INTERVAL="${DZ_FIND_INTERVAL:-15}"
DZ_STATUS_RETRIES="${DZ_STATUS_RETRIES:-12}"  # status poll: ~2 min at 10s (docs: ~1 min for GRE)
DZ_STATUS_INTERVAL="${DZ_STATUS_INTERVAL:-10}"
DZ_LATENCY_RETRIES="${DZ_LATENCY_RETRIES:-3}" # device discovery: docs say wait 10-20s + retry
DZ_LATENCY_INTERVAL="${DZ_LATENCY_INTERVAL:-15}"

# --- helpers -----------------------------------------------------------------
_dz_address()  { run_capture doublezero address 2>/dev/null || true; }   # the DoubleZero ID (from id.json)
_dz_staked_pubkey() { "$SOLANA_BIN/solana-keygen" pubkey "$1" 2>/dev/null || true; }
_dz_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o; for o in ${1//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
}
_dz_detect_public_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}

# run_capture — like run(), but returns the command's stdout (for probes whose
# OUTPUT we need: doublezero address/status/find-validator). Honors dry-run by
# echoing nothing and returning 0. Defined here (not common) to keep the patch
# localized; mockable in tests by shadowing the underlying command.
run_capture() {
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} $*" >&2; return 0; fi
    "$@"
}

# Single DZ decision (also called from Phase 6 validatorcfg so the 2nd shred
# address and Phase 7 prepare track the SAME answer). Precedence:
#   env DZ_ENABLED > recorded state > interactive ask (default N) > skip.
# --yes does NOT auto-enable (a tunnel + key migration is never unattended).
# Idempotent: records dz_enabled to state; safe to call from both phases.
dz_should_enable() {
    local decision
    if [[ -n "${DZ_ENABLED+x}" ]]; then
        decision="$DZ_ENABLED"
    elif [[ -n "$(state_get dz_enabled "")" ]]; then
        decision="$(state_get dz_enabled)"
    elif is_interactive && [[ "${ASSUME_YES:-0}" != "1" ]]; then
        ask "Enable DoubleZero (DZ)? Sets up the tunnel; connect happens after the staked-key swap. [y/N]" "N"
        case "$REPLY" in [Yy]*) decision=true ;; *) decision=false ;; esac
    else
        decision=false
    fi
    state_set dz_enabled "$decision"
    [[ "$decision" == "true" ]]
}

# --- config ------------------------------------------------------------------
dz_resolve_config() {
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (dz-connect/resume run standalone)
    SOLANA_HOME="$(state_get solana_home /root/solana)"
    DZ_KEYPAIR="${DZ_KEYPAIR:-$(state_get dz_keypair "$SOLANA_HOME/dz-keypair.json")}"
    STAKED_KEYPAIR="$(state_get staked_keypair "$SOLANA_HOME/mainnet-validator-keypair.json")"
    # client-ip for `connect ibrl`: explicit env > recorded state > auto-detect.
    [[ -z "${DZ_CLIENT_IP:-}" ]] && DZ_CLIENT_IP="$(state_get dz_client_ip "")"
    [[ -z "${DZ_CLIENT_IP:-}" ]] && DZ_CLIENT_IP="$(_dz_detect_public_ip)"
    state_set dz_keypair "$DZ_KEYPAIR"
    [[ -n "$DZ_CLIENT_IP" ]] && state_set dz_client_ip "$DZ_CLIENT_IP"
}

# ============================================================================
# PART A — Phase 7 prepare
# ============================================================================

# Install doublezero + doublezero-solana. Repo-swap aware: an old (e.g. testnet)
# cloudsmith repo is removed first so the mainnet-beta repo/key take over (docs).
dz_install() {
    step "Installing DoubleZero (mainnet-beta cloudsmith repo + apt)"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would remove any old DZ repo, add ${DZ_SETUP_URL}, then apt-get install doublezero doublezero-solana"
        return 0
    fi
    # Swap any pre-existing DZ apt repo (testnet -> mainnet-beta).
    local f
    while IFS= read -r -d '' f; do
        warn "Removing existing DZ apt source: $f"; run rm -f "$f"
    done < <(find /etc/apt /usr/share/keyrings -name '*doublezero*' -print0 2>/dev/null)
    local setup; setup=$(_mktemp)
    curl -1sLf "$DZ_SETUP_URL" -o "$setup"
    bash "$setup"
    rm -f "$setup"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get install -y doublezero doublezero-solana
}

# doublezerod systemd override -> mainnet-beta (+ metrics, per docs). Enabled on
# boot so the tunnel can restore after the isolation reboot.
dz_env_override() {
    step "DoubleZero env override -> ${DZ_ENV}"
    write_file "$DZ_OVERRIDE_CONF" \
"[Service]
ExecStart=
ExecStart=/usr/bin/doublezerod -sock-file /run/doublezerod/doublezerod.sock -env ${DZ_ENV} -metrics-enable -metrics-addr localhost:2113
"
    run systemctl daemon-reload
    run systemctl enable doublezerod
    run systemctl restart doublezerod
    run doublezero config set --env "$DZ_ENV"
}

# Firewall (official UFW form): GRE + BGP (doublezero0 link-local 179) + 44880/udp
# (route-liveness, per docs). Idempotent (ufw allow dedups).
dz_ufw() {
    step "ufw: GRE + BGP + 44880 for DoubleZero"
    run ufw allow proto gre from any to any
    run ufw allow in  on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
    run ufw allow out on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
    run ufw allow in  on doublezero0 to any port 44880 proto udp
    run ufw allow out on doublezero0 to any port 44880 proto udp
}

# The exact commands the operator runs ON THE OLD SERVER to free the DZ ID. The
# same DoubleZero ID active on two machines at once conflicts — and only the OLD
# server can disconnect itself (DeePloy can't reach it). So DeePloy REMINDS: an
# informational heads-up at prepare (plan ahead) + a blocking gate at connect
# (the moment the ID goes live on THIS machine). Shared so both print identically.
_dz_old_server_commands() {
    info "    On the OLD server, run:"
    info "        doublezero disconnect"
    info "        sudo systemctl stop doublezerod"
    info "        sudo systemctl disable doublezerod"
}

# Place the migrated DoubleZero ID. The DZ ID is shared across the operator's
# cluster (per docs) — DeePloy never generates it; the operator places it at
# $DZ_KEYPAIR, or gives a path. Loop until a valid key is installed at
# ~/.config/doublezero/id.json; validate with `doublezero address`.
dz_keypair_migrate() {
    step "DoubleZero ID (migration)"
    run mkdir -p "$DZ_CONFIG_DIR"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would install the DoubleZero ID to ${DZ_CONFIG_DIR}/id.json and validate with 'doublezero address'"
        return 0
    fi
    local src addr
    while true; do
        src=""
        if [[ -f "$DZ_KEYPAIR" ]]; then
            src="$DZ_KEYPAIR"
        elif is_interactive; then
            warn "No DoubleZero ID at ${DZ_KEYPAIR}."
            info "Place your existing DoubleZero ID at ${DZ_KEYPAIR} (the SAME ID used across your cluster),"
            info "  or enter the path to the key file now."
            ask "DoubleZero ID path (or place it at ${DZ_KEYPAIR} then press Enter)" "$DZ_KEYPAIR"
            src="$REPLY"
        else
            fail "DoubleZero ID absent at ${DZ_KEYPAIR} and run is non-interactive. Place it (chmod 600) and re-run 'deeploy.sh install --only 7'."
        fi
        if [[ -n "$src" && -f "$src" ]]; then
            run install -m 600 "$src" "$DZ_CONFIG_DIR/id.json"
            [[ "$src" != "$DZ_KEYPAIR" ]] && run install -m 600 "$src" "$DZ_KEYPAIR"   # keep the canonical copy too
            addr="$(_dz_address)"
            if [[ -n "$addr" ]]; then
                ok "DoubleZero ID installed (${addr})"
                state_set dz_id "$addr"
                # Early heads-up (informational; NOT a gate — this box isn't
                # connecting yet). The same DZ ID is live on the OLD server; plan
                # to disconnect it there before running 'deeploy dz-connect' here.
                warn "This DoubleZero ID is the SAME one currently active on your OLD server."
                info "Before you run 'deeploy dz-connect' on THIS machine, DoubleZero must be"
                info "disconnected on the OLD server (the same DZ ID can't be active on two"
                info "machines at once). Plan for it now:"
                _dz_old_server_commands
                return 0
            fi
            warn "Installed key at ${DZ_CONFIG_DIR}/id.json but 'doublezero address' returned nothing — not a valid DZ ID?"
        else
            warn "No file at '${src:-<empty>}'."
        fi
        # loop and re-prompt (interactive only; non-interactive already failed)
    done
}

# Confirm DZ devices are reachable (docs: wait 10-20s, retry).
dz_latency() {
    step "DoubleZero device discovery (latency)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would run 'doublezero latency' (retry until devices appear)"; return 0; fi
    local i out
    for ((i=1; i<=DZ_LATENCY_RETRIES; i++)); do
        out="$(run_capture doublezero latency 2>/dev/null || true)"
        if [[ -n "$out" && "$out" =~ [0-9] ]]; then ok "DZ devices discovered"; return 0; fi
        info "No DZ devices yet (attempt ${i}/${DZ_LATENCY_RETRIES}) — waiting ${DZ_LATENCY_INTERVAL}s…"
        sleep "$DZ_LATENCY_INTERVAL"
    done
    warn "No DZ devices discovered after ${DZ_LATENCY_RETRIES} tries — continuing (connect happens later in dz-connect)"
    return 0
}

dz_print_connect() {
    step "MANUAL after the staked-key swap: deeploy dz-connect"
    info "DoubleZero is PREPARED (package, env, firewall, ID, devices) but NOT connected."
    info "Connection needs the validator in gossip + the leader schedule, which only"
    info "happens AFTER you swap to the real staked identity. So, in order:"
    info "  1) reboot completes -> node syncs -> 'catchup 0' on the unstaked identity"
    info "  2) you manually set-identity to the real staked key (see the Start summary)"
    info "  3) run:  deeploy dz-connect    (polls gossip/leader-schedule, then passport + connect + multicast)"
}

# Phase 7 orchestrator — PREPARE ONLY.
doublezero_run() {
    require_root
    dz_resolve_config
    dz_install
    dz_env_override
    dz_ufw
    dz_keypair_migrate
    dz_latency
    # NB: no local 'doublezero disconnect' here. On a fresh box there is no tunnel
    # to drop (it'd be a no-op/error), and the disconnect that actually matters is
    # on the OLD server — which DeePloy can't reach. The operator was reminded in
    # dz_keypair_migrate (heads-up) and is gated in dz-connect (before connect).
    state_set dz_prepared "$(_ts)"
    dz_print_connect
    ok "DoubleZero prepared — run 'deeploy dz-connect' after the staked-key swap"
}

# ============================================================================
# PART B — deeploy dz-connect  (post-swap; Path 1, primary only)
# ============================================================================

# Poll passport find-validator until the validator is in gossip AND the leader
# schedule (the 5-10 min post-swap window). Returns 0 once visible.
_dz_await_in_leader_schedule() {
    local i out
    for ((i=1; i<=DZ_FIND_RETRIES; i++)); do
        out="$(run_capture doublezero-solana passport find-validator -u "$DZ_ENV" 2>&1 || true)"
        if grep -qi 'leader schedul' <<<"$out"; then
            ok "Validator is in gossip + leader schedule"
            return 0
        fi
        info "Waiting for the validator to appear in gossip + leader schedule (attempt ${i}/${DZ_FIND_RETRIES}, ~${DZ_FIND_INTERVAL}s)…"
        sleep "$DZ_FIND_INTERVAL"
    done
    fail "Validator never appeared in the leader schedule after $((DZ_FIND_RETRIES * DZ_FIND_INTERVAL))s. Confirm the staked-key swap completed and the node is voting, then re-run 'deeploy dz-connect'."
}

# Passport: prepare -> sign (with the STAKED key) -> request. Path 1 = primary
# only (no --backup-validator-ids; service_key has no backup_ids).
dz_passport() {
    local dz_id=$1 staked_id=$2 sig sig_raw
    step "DoubleZero passport access (primary validator ${staked_id})"
    run doublezero-solana passport prepare-validator-access -u "$DZ_ENV" \
        --doublezero-address "$dz_id" --primary-validator-id "$staked_id"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would sign-offchain-message (staked key) and submit request-validator-access"
        return 0
    fi
    sig_raw=$("$SOLANA_BIN/solana" sign-offchain-message "service_key=${dz_id}" -k "$STAKED_KEYPAIR" 2>/dev/null || true)
    sig=$(printf '%s\n' "$sig_raw" | awk 'NF{last=$0} END{print last}' | tr -d '[:space:]')
    [[ "$sig" =~ ^[1-9A-HJ-NP-Za-km-z]{40,}$ ]] || fail "Could not parse a base58 signature from sign-offchain-message output"
    run doublezero-solana passport request-validator-access \
        --doublezero-address "$dz_id" --primary-validator-id "$staked_id" \
        --signature "$sig" -u "$DZ_ENV" -k "$STAKED_KEYPAIR"
    ok "Passport access requested"
}

dz_connect_ibrl() {
    step "DoubleZero connect ibrl (client-ip ${DZ_CLIENT_IP:-auto})"
    if [[ -n "${DZ_CLIENT_IP:-}" ]]; then run doublezero connect ibrl --client-ip "$DZ_CLIENT_IP"
    else run doublezero connect ibrl; fi
}

# Poll `doublezero status` until the tunnel is up (docs: ~1 min for GRE init).
dz_status_wait() {
    step "Waiting for the DoubleZero tunnel (doublezero status)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would poll 'doublezero status' until up"; return 0; fi
    local i out
    for ((i=1; i<=DZ_STATUS_RETRIES; i++)); do
        out="$(run_capture doublezero status 2>&1 || true)"
        if grep -qiE '\bup\b|connected' <<<"$out"; then ok "DoubleZero tunnel up"; return 0; fi
        info "Tunnel not up yet (attempt ${i}/${DZ_STATUS_RETRIES}, ~${DZ_STATUS_INTERVAL}s)…"
        sleep "$DZ_STATUS_INTERVAL"
    done
    warn "Tunnel not 'up' after $((DZ_STATUS_RETRIES * DZ_STATUS_INTERVAL))s — check 'doublezero status' / doublezerod logs"
    return 0
}

dz_multicast_publish() {
    step "DoubleZero multicast publish (edge-solana-shreds)"
    # No validator restart: the multicast shred-address is already in validator.sh
    # (Phase 6, gated on dz_enabled) and is picked up live.
    run doublezero connect multicast --publish edge-solana-shreds
}

# Blocking gate, run right before this machine connects (the moment the DZ ID
# goes live here). The same ID active on two machines conflicts; only the OLD
# server can disconnect itself. Requires explicit acknowledgment; does NOT honor
# --yes (a conflict guard, like require_yes); fails clearly non-interactively.
dz_confirm_old_server_disconnected() {
    step "Before connecting: the OLD server must be disconnected"
    warn "The same DoubleZero ID active on two machines at once WILL conflict."
    info "Confirm DoubleZero is disconnected on your OLD server first."
    _dz_old_server_commands
    if ! is_interactive; then
        fail "Cannot confirm the OLD server is disconnected in a non-interactive run. On the OLD server run 'doublezero disconnect' (then stop/disable doublezerod), then re-run 'deeploy dz-connect'."
    fi
    printf '%s  Has the OLD server been disconnected (doublezerod stopped)?%s [y/N]: ' "$C_BOLD" "$C_NC"
    local reply; read -r reply || reply=""
    case "$reply" in [Yy]*) ok "Acknowledged — proceeding to connect this machine." ;;
        *) fail "Disconnect DoubleZero on the OLD server first, then re-run 'deeploy dz-connect'." ;; esac
}

dz_connect_run() {
    require_root
    dz_resolve_config
    [[ "$(state_get dz_prepared "")" != "" ]] || fail "DoubleZero was not prepared — run the install Phase 7 prepare first ('deeploy.sh install --only 7')."
    [[ -f "$STAKED_KEYPAIR" ]] || fail "Staked key not at ${STAKED_KEYPAIR}. Complete the manual set-identity swap before 'deeploy dz-connect'."
    local dz_id staked_id
    dz_id="$(state_get dz_id "")"; [[ -z "$dz_id" ]] && dz_id="$(_dz_address)"
    [[ -n "$dz_id" ]] || fail "Could not determine the DoubleZero ID (doublezero address). Re-run Phase 7 prepare."
    staked_id="$(_dz_staked_pubkey "$STAKED_KEYPAIR")"   # intentional staked-key read (passport needs it) — ONLY here
    [[ -n "$staked_id" ]] || fail "Could not read the staked validator pubkey from ${STAKED_KEYPAIR}"

    _dz_await_in_leader_schedule              # the 5-10 min gossip/leader-schedule window
    dz_passport "$dz_id" "$staked_id"
    dz_confirm_old_server_disconnected        # blocking gate BEFORE connect (the ID goes live here)
    dz_connect_ibrl
    dz_status_wait
    dz_multicast_publish
    state_set dz_connected "$(_ts)"
    ok "DoubleZero connected (passport + ibrl + multicast). 'doublezero status' to inspect."
}

# ============================================================================
# Post-reboot resume — only meaningful AFTER dz-connect has run (a tunnel exists
# to verify/restore). Before connect, there is nothing to restore -> no-op.
# ============================================================================
_dz_iface_up() { ip link show doublezero0 >/dev/null 2>&1; }

dz_resume() {
    require_root
    if [[ "$(state_get dz_connected "")" == "" ]]; then
        info "DoubleZero prepared but not yet connected (run 'deeploy dz-connect' after the swap) — nothing to restore."
        return 0
    fi
    dz_resolve_config
    step "DoubleZero post-reboot check (doublezero0)"
    if _dz_iface_up; then
        ok "doublezero0 is up — tunnel restored automatically by doublezerod (no re-connect needed)"
        return 0
    fi
    warn "doublezero0 not up after reboot — restoring the tunnel from saved settings (no re-prompt)"
    run systemctl restart doublezerod
    dz_connect_ibrl
    dz_multicast_publish
    if _dz_iface_up; then ok "doublezero0 restored"
    else warn "doublezero0 still not up — check 'doublezero status' / doublezerod logs"; fi
}
