#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/keys.sh   (Phase 5: identities)
# Generate the THROWAWAY fake identity + an unstaked identity, point the CLI at
# mainnet, take the vote-account pubkey, and PRINT where the REAL staked key
# goes. DeePloy NEVER generates, moves, or reads the real staked key — the node
# syncs on the fake identity and the operator hot-swaps manually at the end.
#
# Safety: keys are never regenerated if they already exist (regenerating a live
# validator's identity would be catastrophic). The failover script's
# "staked == unstaked -> FAIL" guard is lifted here and extended.
#
# Requires: common.sh sourced. The solana toolchain (Phase 4) provides
# solana-keygen/solana under $SOLANA_BIN; tests override the thin wrappers.
# ============================================================================

[[ -n "${_DEEPLOY_KEYS_SOURCED:-}" ]] && return 0
_DEEPLOY_KEYS_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-$HOME/.local/share/solana/install/active_release/bin}"
KEYS_RPC_URL="${KEYS_RPC_URL:-https://api.mainnet-beta.solana.com}"

# --- thin wrappers (overridden in tests) -------------------------------------
_keys_keygen_new() { run "$SOLANA_BIN/solana-keygen" new --no-bip39-passphrase --silent -o "$1"; }
_keys_pubkey()     { "$SOLANA_BIN/solana-keygen" pubkey "$1" 2>/dev/null; }
_keys_solana()     { run "$SOLANA_BIN/solana" "$@"; }

# Solana base58 pubkey: 32-44 chars, no 0 O I l.
_keys_valid_pubkey() { [[ "$1" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; }

# --- config resolution -------------------------------------------------------
keys_resolve_config() {
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (consistent across phases)
    local home; home="$(state_get solana_home /root/solana)"
    FAKE_IDENTITY="${FAKE_IDENTITY:-$home/mvkfake/mainnet-validator-keypair.json}"
    UNSTAKED_KEYPAIR="${UNSTAKED_KEYPAIR:-$home/unstaked-identity.json}"
    STAKED_KEYPAIR="${STAKED_KEYPAIR:-$home/mainnet-validator-keypair.json}"
    LEDGER_PATH="$(state_get ledger_path "$home/ledger")"

    if [[ -z "${VOTE_ACCOUNT_PUBKEY:-}" ]]; then
        ask "Vote account pubkey (your existing vote account)" "${VOTE_ACCOUNT_PUBKEY:-}"
        VOTE_ACCOUNT_PUBKEY="$REPLY"
    fi
    _keys_valid_pubkey "$VOTE_ACCOUNT_PUBKEY" || fail "Vote account pubkey looks invalid: '${VOTE_ACCOUNT_PUBKEY}'"

    state_set fake_identity      "$FAKE_IDENTITY"
    state_set unstaked_keypair   "$UNSTAKED_KEYPAIR"
    state_set staked_keypair     "$STAKED_KEYPAIR"
    state_set vote_account_pubkey "$VOTE_ACCOUNT_PUBKEY"
}

# --- CLI config --------------------------------------------------------------
keys_config_cli() {
    step "solana CLI config (mainnet, keypair path)"
    _keys_solana config set --url "$KEYS_RPC_URL"
    # Points at the REAL key PATH (placed manually later) for operator CLI use;
    # this only stores a path string — it does not require the file to exist.
    _keys_solana config set --keypair "$STAKED_KEYPAIR"
}

# --- generation (idempotent; never regenerate an existing key) ---------------
_keys_generate_one() {
    local path=$1 label=$2
    if [[ -f "$path" ]]; then
        ok "${label} already present ($(_keys_pubkey "$path")) — NOT regenerated"
        return 0
    fi
    run mkdir -p "$(dirname "$path")"
    _keys_keygen_new "$path"
    is_dry_run || ok "${label} generated: $(_keys_pubkey "$path")"
}

keys_generate() {
    step "Generating throwaway identities"
    _keys_generate_one "$FAKE_IDENTITY"    "Fake validator identity (mvkfake)"
    _keys_generate_one "$UNSTAKED_KEYPAIR" "Unstaked identity"
}

# --- validation (the foolproofing) -------------------------------------------
keys_validate() {
    is_dry_run && return 0
    local fake unstaked staked
    fake="$(_keys_pubkey "$FAKE_IDENTITY")"
    unstaked="$(_keys_pubkey "$UNSTAKED_KEYPAIR")"
    [[ -n "$fake" ]]     || fail "Could not read fake identity pubkey from $FAKE_IDENTITY"
    [[ -n "$unstaked" ]] || fail "Could not read unstaked identity pubkey from $UNSTAKED_KEYPAIR"
    [[ "$fake" == "$unstaked" ]] && fail "Fake identity and unstaked identity are THE SAME key!"
    [[ "$fake" == "$VOTE_ACCOUNT_PUBKEY" ]] && fail "Vote account equals the identity — they must be different accounts"

    if [[ -f "$STAKED_KEYPAIR" ]]; then
        staked="$(_keys_pubkey "$STAKED_KEYPAIR")"
        [[ "$staked" == "$fake" ]]     && fail "Real staked key equals the fake identity — defeats the throwaway-sync design"
        [[ "$staked" == "$unstaked" ]] && fail "Real staked key equals the unstaked identity — wrong key in place"
        warn "A key already exists at the real-key path ($STAKED_KEYPAIR) — DeePloy left it untouched"
    fi
    ok "Identity checks passed (fake != unstaked, vote != identity)"
    info "  fake identity:  $fake"
    info "  unstaked:       $unstaked"
    info "  vote account:   $VOTE_ACCOUNT_PUBKEY"
}

# --- manual real-key instructions --------------------------------------------
keys_print_manual() {
    step "MANUAL: the real staked key (DeePloy will not touch it)"
    warn "DeePloy never generates, copies, or reads your real staked validator key."
    info "The node syncs on the throwaway fake identity. After 'catchup 0', you hot-swap manually."
    info ""
    info "1) Place your real staked keypair at:"
    info "     ${STAKED_KEYPAIR}     (chmod 600; never commit; never paste its contents)"
    info "2) After the node reaches 'catchup 0', swap identity (also printed in the final summary):"
    info "     agave-validator --ledger ${LEDGER_PATH} set-identity ${STAKED_KEYPAIR}"
    info "     agave-validator --ledger ${LEDGER_PATH} authorized-voter add ${STAKED_KEYPAIR}"
    info "   No tower transfer needed: a fresh node with no local tower rebuilds its vote floor from the cluster."
}

# --- orchestrator ------------------------------------------------------------
keys_run() {
    require_root
    keys_resolve_config
    keys_config_cli
    keys_generate
    keys_validate
    keys_print_manual
}
