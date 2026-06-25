#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/keys.sh   (Phase 5: identities)
# Generate ONE throwaway "sync identity" (unstaked-identity.json), point the CLI
# at mainnet, take the vote-account pubkey, and PRINT where the REAL staked key
# goes. DeePloy NEVER generates, moves, or reads the real staked key — the node
# SYNCS on this unstaked identity, the operator hot-swaps to the real staked key
# manually after 'catchup 0', and failover later returns to this same key.
#
# One key, not two: the file is unstaked-identity.json (operator's terminology);
# the role is the "sync identity" (what the node runs under until the swap), so
# the state var is sync_identity. (Earlier versions also made a separate mvkfake
# key — dropped; a single throwaway is both the sync identity and the failover
# safe-harbor.)
#
# Safety: the key is never regenerated if it already exists (regenerating a live
# validator's identity would be catastrophic). vote != identity and
# staked != sync-identity are enforced.
#
# Requires: common.sh sourced. The solana toolchain (Phase 4) provides
# solana-keygen/solana under $SOLANA_BIN; tests override the thin wrappers.
# ============================================================================

[[ -n "${_DEEPLOY_KEYS_SOURCED:-}" ]] && return 0
_DEEPLOY_KEYS_SOURCED=1

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
    # One throwaway key: the file keeps the operator's name (unstaked-identity.json),
    # its ROLE is the sync identity (UNSTAKED_KEYPAIR env/conf still accepted in).
    SYNC_IDENTITY="${SYNC_IDENTITY:-${UNSTAKED_KEYPAIR:-$home/unstaked-identity.json}}"
    STAKED_KEYPAIR="${STAKED_KEYPAIR:-$home/mainnet-validator-keypair.json}"
    LEDGER_PATH="$(state_get ledger_path "$home/ledger")"

    if [[ -z "${VOTE_ACCOUNT_PUBKEY:-}" ]]; then
        ask "Vote account pubkey (your existing vote account)" "${VOTE_ACCOUNT_PUBKEY:-}"
        VOTE_ACCOUNT_PUBKEY="$REPLY"
    fi
    _keys_valid_pubkey "$VOTE_ACCOUNT_PUBKEY" || fail "Vote account pubkey looks invalid: '${VOTE_ACCOUNT_PUBKEY}'"

    state_set sync_identity       "$SYNC_IDENTITY"
    state_set staked_keypair      "$STAKED_KEYPAIR"
    state_set vote_account_pubkey "$VOTE_ACCOUNT_PUBKEY"
}

# --- CLI config --------------------------------------------------------------
keys_config_cli() {
    step "solana CLI config (mainnet, keypair path)"
    # One combined `config set` (url + keypair) so the CLI prints its config block
    # ONCE, not twice. The keypair points at the REAL key PATH (placed manually
    # later) for operator CLI use — it only stores a path string, file need not exist.
    _keys_solana config set --url "$KEYS_RPC_URL" --keypair "$STAKED_KEYPAIR"
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
    step "Generating the unstaked sync identity"
    _keys_generate_one "$SYNC_IDENTITY" "Unstaked sync identity"
}

# --- validation (the foolproofing) -------------------------------------------
keys_validate() {
    is_dry_run && return 0
    local sync staked
    sync="$(_keys_pubkey "$SYNC_IDENTITY")"
    [[ -n "$sync" ]] || fail "Could not read sync-identity pubkey from $SYNC_IDENTITY"
    [[ "$sync" == "$VOTE_ACCOUNT_PUBKEY" ]] && fail "Vote account equals the identity — they must be different accounts"

    if [[ -f "$STAKED_KEYPAIR" ]]; then
        staked="$(_keys_pubkey "$STAKED_KEYPAIR")"
        [[ "$staked" == "$sync" ]] && fail "Real staked key equals the sync identity — defeats the throwaway-sync design (wrong key in place)"
        warn "A key already exists at the real-key path ($STAKED_KEYPAIR) — DeePloy left it untouched"
    fi
    ok "Identity checks passed (vote != identity, staked != sync)"
    info "  sync identity:  $sync   ($SYNC_IDENTITY)"
    info "  vote account:   $VOTE_ACCOUNT_PUBKEY"
}

# --- manual real-key instructions --------------------------------------------
keys_print_manual() {
    step "MANUAL: the real staked key (DeePloy will not touch it)"
    warn "DeePloy never generates, copies, or reads your real staked validator key."
    info "The node syncs on the unstaked sync identity. After 'catchup 0', you hot-swap manually."
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
    # SOFT DoubleZero ID presence check (non-blocking) — reminds the operator to
    # place the DZ ID; the HARD check is in dz-connect. Gated on dz_enabled inside.
    declare -F dz_keypair_check_soft >/dev/null 2>&1 && dz_keypair_check_soft
}
