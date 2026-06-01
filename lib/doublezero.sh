#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/doublezero.sh   (Phase 7: DoubleZero, optional)
# Automates everything that does NOT need the staked key:
#   install -> dz-keypair -> env override (mainnet-beta) -> ufw GRE (before
#   connect) -> connect ibrl --client-ip <auto> -> ufw BGP (after connect, on
#   doublezero0) -> multicast publish.
# The staked-key steps (passport access + revenue-distribution deposit) are
# deferred to `deeploy dz-finalize`, run AFTER the manual identity swap.
#
# Firewall uses the OFFICIAL UFW form (not a /etc/ufw/before.rules edit):
#   * idempotent (native `ufw allow` dedups);
#   * BGP scoped to doublezero0 + link-local only (not 179/tcp globally);
#   * no system-file edit for GRE.
# Ordering: GRE rule before connect; BGP rules AFTER connect (doublezero0 only
# exists once `connect ibrl` brings the interface up).
#
# Requires: common.sh sourced. doublezero/doublezero-solana/solana(-keygen)/ufw/
# systemctl/curl are mockable; paths overridable for tests.
# ============================================================================

[[ -n "${_DEEPLOY_DOUBLEZERO_SOURCED:-}" ]] && return 0
_DEEPLOY_DOUBLEZERO_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-$HOME/.local/share/solana/install/active_release/bin}"
DZ_SETUP_URL="${DZ_SETUP_URL:-https://dl.cloudsmith.io/public/malbeclabs/doublezero/setup.deb.sh}"
DZ_CONFIG_DIR="${DZ_CONFIG_DIR:-$HOME/.config/doublezero}"
DZ_OVERRIDE_CONF="${DZ_OVERRIDE_CONF:-/etc/systemd/system/doublezerod.service.d/override.conf}"

_dz_pubkey()   { "$SOLANA_BIN/solana-keygen" pubkey "$1" 2>/dev/null || true; }   # set -e: empty on bad/missing key, caller checks
_dz_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o; for o in ${1//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
}

# Public IP for `connect ibrl --client-ip`. Prefer the local routing table (no
# external call); on a NAT'd src, the operator is asked to enter it.
_dz_detect_public_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# --- config ------------------------------------------------------------------
dz_resolve_config() {
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (dz-finalize may run standalone)
    SOLANA_HOME="$(state_get solana_home /root/solana)"
    DZ_KEYPAIR="${DZ_KEYPAIR:-$SOLANA_HOME/dz-keypair.json}"
    DZ_ENV="${DZ_ENV:-mainnet-beta}"
    DZ_MULTICAST="${DZ_MULTICAST:-false}"
    STAKED_KEYPAIR="$(state_get staked_keypair "$SOLANA_HOME/mainnet-validator-keypair.json")"
    if [[ -z "${DZ_CLIENT_IP:-}" ]]; then
        local det; det=$(_dz_detect_public_ip)
        ask "Public IP for DoubleZero (connect ibrl --client-ip)" "$det"
        DZ_CLIENT_IP="$REPLY"
    fi
    _dz_valid_ip "$DZ_CLIENT_IP" || fail "Invalid public IP for DoubleZero: '${DZ_CLIENT_IP}'"
    state_set dz_keypair   "$DZ_KEYPAIR"
    state_set dz_client_ip "$DZ_CLIENT_IP"
    state_set dz_multicast "$DZ_MULTICAST"
}

# --- install -----------------------------------------------------------------
dz_install() {
    step "Installing DoubleZero (cloudsmith repo + apt)"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would add ${DZ_SETUP_URL} repo, then apt-get install doublezero doublezero-solana"
        return 0
    fi
    local setup; setup=$(_mktemp)
    curl -1sLf "$DZ_SETUP_URL" -o "$setup"
    bash "$setup"
    rm -f "$setup"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get install -y doublezero doublezero-solana
}

# --- dz keypair --------------------------------------------------------------
# A deploy is USUALLY a migration: the operator carries the SAME dz-keypair over
# from another server. That key is production material DeePloy never invents — it
# must be placed MANUALLY — and DoubleZero must be shut down on the OLD server
# first (the same key connected on two boxes at once conflicts). Only a genuinely
# fresh setup generates a new key. The mode is asked EXPLICITLY (default
# migration) so an unplaced key can never silently become a brand-new identity
# (which would break the migration). DZ_KEY_MODE overrides the prompt for
# reproducible/--config runs and tests.
DZ_KEY_MODE="${DZ_KEY_MODE:-}"          # "migration" | "fresh"; empty => ask (default migration)

_dz_migration_warning() {
    warn "MIGRATION: this DZ key may still be ACTIVE on another server."
    warn "Two servers connected on the SAME DoubleZero key at once WILL conflict."
    info "On the OLD server, run these BEFORE this new server connects:"
    info "    doublezero disconnect"
    info "    sudo systemctl stop doublezerod"
    info "    sudo systemctl disable doublezerod"
}

# Block until a VALID existing keypair is present at $DZ_KEYPAIR. The operator
# places it by hand (in another shell), then continues; the loop re-checks. A
# non-interactive run can't place a file, so it FAILS with a clear pointer rather
# than hanging or silently generating a wrong key.
_dz_await_migrated_key() {
    local pk
    while true; do
        if [[ -f "$DZ_KEYPAIR" ]]; then
            pk="$(_dz_pubkey "$DZ_KEYPAIR")"
            [[ -n "$pk" ]] && { ok "dz-keypair present and valid (${pk}) — using it (migration; never regenerated)"; return 0; }
            warn "File at ${DZ_KEYPAIR} is not a readable Solana keypair (solana-keygen pubkey failed)."
        else
            warn "No dz-keypair found at ${DZ_KEYPAIR}."
        fi
        if ! is_interactive; then
            fail "Migration needs your EXISTING dz-keypair at ${DZ_KEYPAIR} (the SAME key active on your old DoubleZero server), but it is absent/invalid and this run is non-interactive. Place it (chmod 600) and re-run 'deeploy.sh install --only 7' interactively (or set DZ_KEY_MODE=fresh to generate a new key)."
        fi
        info "Place your existing dz-keypair at:  ${DZ_KEYPAIR}   (chmod 600)"
        info "  — the SAME key currently active on your OLD DoubleZero server."
        info "  In another shell: copy the keypair JSON to that path, then return here."
        ask "Press Enter once the key is in place" ""    # blocking; the loop re-checks
    done
}

_dz_keypair_migration() {
    _dz_await_migrated_key                  # waits for a valid placed key (or fails non-interactively)
    _dz_migration_warning
    if ! confirm "Confirm the OLD server is disconnected and doublezerod is stopped" N; then
        fail "Shut DoubleZero down on the old server first (same DZ key on two boxes = conflict), then re-run"
    fi
}

_dz_keypair_fresh() {
    # Refuse to clobber an existing key on a 'fresh' choice — it may be the
    # operator's production DZ key (mirrors disk.sh / symlink no-clobber).
    if [[ -f "$DZ_KEYPAIR" ]]; then
        fail "A key already exists at ${DZ_KEYPAIR} but you chose to generate a FRESH one. Refusing to overwrite it (it may be your production DZ key). Move it aside, or choose migration, then re-run."
    fi
    warn "Generating a NEW dz-keypair at ${DZ_KEYPAIR} (fresh setup, not a migration)"
    run mkdir -p "$(dirname "$DZ_KEYPAIR")"
    run "$SOLANA_BIN/solana-keygen" new --no-bip39-passphrase --silent -o "$DZ_KEYPAIR"
}

dz_keypair() {
    step "DoubleZero keypair"
    local mode="${DZ_KEY_MODE:-}"
    if [[ -z "$mode" ]]; then
        ask_choice "DoubleZero key — migrate your existing key from another server, or generate a fresh one?" "migration" migration fresh
        mode="$REPLY"
    fi
    case "$mode" in
        migration) _dz_keypair_migration ;;
        fresh)     _dz_keypair_fresh ;;
        *)         fail "Unknown DZ_KEY_MODE '${mode}' (expected migration|fresh)" ;;
    esac
    run mkdir -p "$DZ_CONFIG_DIR"
    run cp "$DZ_KEYPAIR" "$DZ_CONFIG_DIR/id.json"
}

# --- env override (mainnet-beta) ---------------------------------------------
dz_env_override() {
    step "DoubleZero env override -> ${DZ_ENV}"
    write_file "$DZ_OVERRIDE_CONF" \
"[Service]
ExecStart=
ExecStart=/usr/bin/doublezerod -sock-file /run/doublezerod/doublezerod.sock -env ${DZ_ENV}
"
    run systemctl daemon-reload
    run systemctl restart doublezerod
    run doublezero config set --env "$DZ_ENV"
}

# --- firewall (official UFW form; GRE before connect, BGP after) -------------
dz_ufw_gre() {
    step "ufw: GRE for the DoubleZero tunnel"
    run ufw allow proto gre from any to any
}
dz_ufw_bgp() {
    step "ufw: BGP on doublezero0 (link-local only)"
    run ufw allow in  on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
    run ufw allow out on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
}

# --- connect -----------------------------------------------------------------
dz_connect_ibrl() {
    step "DoubleZero connect ibrl (client-ip ${DZ_CLIENT_IP})"
    run doublezero connect ibrl --client-ip "$DZ_CLIENT_IP"
}
dz_multicast() {
    [[ "$DZ_MULTICAST" == "true" ]] || { info "DZ multicast disabled — skipping publish"; return 0; }
    step "DoubleZero multicast publish (edge-solana-shreds)"
    run doublezero connect multicast --publish edge-solana-shreds
}

# --- manual pointer ----------------------------------------------------------
dz_print_finalize() {
    step "MANUAL after staked-key swap: deeploy dz-finalize"
    info "Passport access needs the REAL staked key to sign (absent at deploy time)."
    info "After the manual set-identity swap, run:  deeploy dz-finalize"
    info "  passport: prepare-validator-access -> sign-offchain-message -> request-validator-access"
}

# --- orchestrator (deploy-time) ----------------------------------------------
doublezero_run() {
    require_root
    dz_resolve_config
    dz_install
    dz_keypair
    dz_env_override
    dz_ufw_gre            # GRE BEFORE connect
    dz_connect_ibrl       # brings up doublezero0
    dz_ufw_bgp            # BGP AFTER connect (interface now exists)
    dz_multicast
    dz_print_finalize
}

# ============================================================================
# deeploy dz-finalize — run AFTER the manual staked-key swap (needs the key).
# ============================================================================
# Passport runs on EVERY new-server connection (never wasteful). Addresses are
# computed from the keys: --doublezero-address = dz-keypair pubkey,
# --primary-validator-id = staked pubkey, service_key = the dz-address.
dz_finalize_passport() {
    local dz_addr=$1 staked_id=$2 sig sig_raw
    step "DoubleZero passport access request"
    run doublezero-solana passport prepare-validator-access -u "$DZ_ENV" \
        --doublezero-address "$dz_addr" --primary-validator-id "$staked_id"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would sign-offchain-message and submit request-validator-access"
        return 0
    fi
    # Sign with the REAL staked key, then chain the signature into the request.
    sig_raw=$("$SOLANA_BIN/solana" sign-offchain-message "service_key=${dz_addr}" -k "$STAKED_KEYPAIR" 2>/dev/null || true)
    # The signature is the last non-empty line of stdout (a lone base58 string).
    sig=$(printf '%s\n' "$sig_raw" | awk 'NF{last=$0} END{print last}' | tr -d '[:space:]')
    [[ "$sig" =~ ^[1-9A-HJ-NP-Za-km-z]{40,}$ ]] || fail "Could not parse a base58 signature from sign-offchain-message output"
    run doublezero-solana passport request-validator-access \
        --doublezero-address "$dz_addr" --primary-validator-id "$staked_id" \
        --signature "$sig" -u "$DZ_ENV" -k "$STAKED_KEYPAIR"
    ok "Passport access requested"
}

dz_finalize_run() {
    require_root
    dz_resolve_config
    [[ -f "$STAKED_KEYPAIR" ]] || fail "Real staked key not at ${STAKED_KEYPAIR} — place it and swap identity before dz-finalize"
    local dz_addr staked_id
    dz_addr=$(_dz_pubkey "$DZ_KEYPAIR")
    staked_id=$(_dz_pubkey "$STAKED_KEYPAIR")
    [[ -n "$dz_addr" && -n "$staked_id" ]] || fail "Could not read DZ/staked pubkeys"
    dz_finalize_passport "$dz_addr" "$staked_id"   # passport only — no validator-deposit
}
