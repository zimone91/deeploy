#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/keys.sh   (Phase 5: identities)
# Generate ONE throwaway "sync identity" (unstaked-identity.json), point the CLI
# at mainnet, take the vote-account pubkey, ask where the REAL staked key lives,
# and PRINT the hot swap. DeePloy NEVER generates, copies, moves, or transmits
# the real staked key. Two modes (staked_key_mode):
#   file   (default) the operator places the keypair on this box; DeePloy reads
#          it read-only: to derive its pubkey, and in dz-connect, where it signs
#          the passport message and the request transaction it pays for.
#   offbox the keypair never has to be on this box: DeePloy knows only its
#          pubkey and consults no staked keypair path; the operator pipes the
#          key to set-identity over ssh.
# The node SYNCS on this unstaked identity, the operator hot-swaps to the real
# staked key manually after 'catchup 0', and failover later returns to this
# same key.
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
_keys_pubkey()     { "$SOLANA_BIN/solana-keygen" pubkey "$1" 2>/dev/null || true; }   # empty = unreadable; 0 always, for $( )
_keys_solana()     { run "$SOLANA_BIN/solana" "$@"; }

# Solana base58 pubkey: 32-44 chars, no 0 O I l.
_keys_valid_pubkey() { [[ "$1" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; }
# ...and exactly 32 bytes once decoded (the regex alone admits 23-33).
_keys_valid_pubkey32() { _keys_valid_pubkey "$1" && [[ "$(b58_len "$1")" == 32 ]]; }

# The vote account's validator identity, on-chain (read-only RPC; mockable).
# stdout: the pubkey, or nothing when the RPC does not answer.
_keys_vote_identity() {
    "$SOLANA_BIN/solana" vote-account "$1" --url "$KEYS_RPC_URL" --output json-compact 2>/dev/null \
        | sed -nE 's/.*"validatorIdentity"[[:space:]]*:[[:space:]]*"([1-9A-HJ-NP-Za-km-z]{32,44})".*/\1/p' | head -1 || true
}

# --- config resolution -------------------------------------------------------
keys_resolve_config() {
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (consistent across phases)
    local home; home="$(state_get solana_home /root/solana)"
    # One throwaway key: the file keeps the operator's name (unstaked-identity.json),
    # its ROLE is the sync identity (UNSTAKED_KEYPAIR env/conf still accepted in).
    SYNC_IDENTITY="${SYNC_IDENTITY:-${UNSTAKED_KEYPAIR:-$home/unstaked-identity.json}}"
    LEDGER_PATH="$(state_get ledger_path "$home/ledger")"

    if [[ -z "${VOTE_ACCOUNT_PUBKEY:-}" ]]; then
        ask "Vote account pubkey (your existing vote account)" "${VOTE_ACCOUNT_PUBKEY:-}"
        VOTE_ACCOUNT_PUBKEY="$REPLY"
    fi
    _keys_valid_pubkey "$VOTE_ACCOUNT_PUBKEY" || fail "Vote account pubkey looks invalid: '${VOTE_ACCOUNT_PUBKEY}'"

    # Where the staked key lives (R10-6). file (default): on this box, and DeePloy
    # reads it read-only. offbox: never on this box — the pubkey is all DeePloy
    # keeps, and no staked keypair path is set, recorded, or consulted.
    if [[ -z "${STAKED_KEY_MODE:-}" ]]; then
        ask_choice "Staked identity key: placed on this box (file) or never on it (offbox)" "$(state_get staked_key_mode file)" file offbox
        STAKED_KEY_MODE="$REPLY"
    fi
    [[ "$STAKED_KEY_MODE" =~ ^(file|offbox)$ ]] || fail "STAKED_KEY_MODE must be 'file' or 'offbox', not '${STAKED_KEY_MODE}'"
    if [[ "$STAKED_KEY_MODE" == offbox ]]; then
        if [[ -z "${STAKED_PUBKEY:-}" ]]; then
            ask "Staked identity PUBKEY (the key itself stays off this box)" "$(state_get staked_pubkey "")"
            STAKED_PUBKEY="$REPLY"
        fi
        _keys_valid_pubkey32 "$STAKED_PUBKEY" || fail "Staked identity pubkey is not a 32-byte base58 key: '${STAKED_PUBKEY}'"
        [[ "$STAKED_PUBKEY" != "$VOTE_ACCOUNT_PUBKEY" ]] || fail "Staked identity equals the vote account — they must be different accounts"
        STAKED_KEYPAIR=""
        state_clear staked_keypair
        state_set staked_pubkey "$STAKED_PUBKEY"
    else
        # Back from offbox: its recorded pubkey is not known to be this file's
        # until phase 5 or dz-connect derives one, so verify must not use it.
        [[ "$(state_get staked_key_mode file)" == offbox ]] && state_clear staked_pubkey
        STAKED_KEYPAIR="${STAKED_KEYPAIR:-$home/mainnet-validator-keypair.json}"
        state_set staked_keypair "$STAKED_KEYPAIR"
    fi

    state_set staked_key_mode     "$STAKED_KEY_MODE"
    state_set sync_identity       "$SYNC_IDENTITY"
    state_set vote_account_pubkey "$VOTE_ACCOUNT_PUBKEY"
}

# --- CLI config --------------------------------------------------------------
keys_config_cli() {
    step "solana CLI config (mainnet, keypair path)"
    # One combined `config set` (url + keypair) so the CLI prints its config block
    # ONCE, not twice. In file mode the keypair points at the REAL key PATH (placed
    # manually later) for operator CLI use — it only stores a path string, file
    # need not exist. In offbox mode there is no staked path: the default is the
    # sync identity, which also pays for the DoubleZero passport request.
    local kp=$STAKED_KEYPAIR
    [[ "${STAKED_KEY_MODE:-file}" == offbox ]] && kp=$SYNC_IDENTITY
    _keys_solana config set --url "$KEYS_RPC_URL" --keypair "$kp"
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

    if [[ "${STAKED_KEY_MODE:-file}" == offbox ]]; then
        staked="$STAKED_PUBKEY"                  # the pubkey is all there is; no path is consulted
        [[ "$staked" == "$sync" ]] && fail "Staked identity pubkey equals the sync identity — defeats the throwaway-sync design (wrong pubkey given)"
    elif [[ -f "$STAKED_KEYPAIR" ]]; then
        staked="$(_keys_pubkey "$STAKED_KEYPAIR")"
        [[ -n "$staked" ]] || fail "Could not read a pubkey from the key at the real-key path ($STAKED_KEYPAIR). Fix that file, or move it off that path, then run again."
        [[ "$staked" == "$sync" ]] && fail "Real staked key equals the sync identity — defeats the throwaway-sync design (wrong key in place)"
        state_set staked_pubkey "$staked"    # derived here anyway; verify reads it
        warn "A key already exists at the real-key path ($STAKED_KEYPAIR) — DeePloy left it untouched"
    fi
    [[ -n "${staked:-}" ]] && keys_check_vote_identity "$staked"
    ok "Identity checks passed (vote != identity, staked != sync)"
    info "  sync identity:  $sync   ($SYNC_IDENTITY)"
    [[ "${STAKED_KEY_MODE:-file}" == offbox ]] && info "  staked identity: $STAKED_PUBKEY   (pubkey only — the key stays off this box)"
    info "  vote account:   $VOTE_ACCOUNT_PUBKEY"
}

# The vote account names the node it votes for ("Validator Identity"). A typo in
# a pubkey that still decodes to 32 bytes is caught only here. Advisory: a
# mismatch warns, no answer from the RPC is info. (R10-6)
keys_check_vote_identity() {    # <staked pubkey>
    local onchain; onchain="$(_keys_vote_identity "$VOTE_ACCOUNT_PUBKEY")"
    if [[ -z "$onchain" ]]; then
        info "Vote account not read from ${KEYS_RPC_URL} — the staked pubkey is not checked against it"
    elif [[ "$onchain" == "$1" ]]; then
        ok "The vote account names the staked identity on-chain (${1})"
    else
        warn "The vote account ${VOTE_ACCOUNT_PUBKEY} names ${onchain} as its validator identity on-chain, not the staked ${1} — check both before the swap"
    fi
}

# --- manual real-key instructions --------------------------------------------
keys_print_manual() {
    if [[ "${STAKED_KEY_MODE:-file}" == offbox ]]; then
        step "MANUAL: the real staked key — offbox, it never has to be on this box"
        warn "DeePloy does not read the staked key: it knows only its pubkey (${STAKED_PUBKEY})."
        info "The node syncs on the unstaked sync identity. After 'catchup 0', hot-swap manually from the"
        info "machine that holds the key, piping it over ssh (also printed in the final summary):"
        keys_print_swap_steps "${SOLANA_BIN}/agave-validator" "$LEDGER_PATH"
        return 0
    fi
    step "MANUAL: the real staked key (DeePloy never generates, copies, or transmits it)"
    warn "DeePloy never generates, copies, or transmits your real staked validator key (read-only: it derives the pubkey; in dz-connect the key signs the passport message and the request transaction it pays for)."
    info "The node syncs on the unstaked sync identity. After 'catchup 0', you hot-swap manually."
    info ""
    info "1) Place your real staked keypair at:"
    info "     ${STAKED_KEYPAIR}     (chmod 600; never commit; never paste its contents)"
    info "2) After the node reaches 'catchup 0', hot-swap (also printed in the final summary):"
    keys_print_swap_steps agave-validator "$LEDGER_PATH" "$STAKED_KEYPAIR"
}

# --- the hot swap — printed in phase 5 and in the final summary --------------
# A hot swap moves the vote history. The old validator stops voting first — and
# a restart of it must come back unstaked, or two nodes vote — and its
# vote_history-<staked-pubkey>.bin comes here, into the ledger
# (votor/src/vote_history_storage.rs 149-157, validator/src/commands/run/
# execute.rs 590-592, jito-solana v4.4.0-rc.1-jito). Without it the votes the old
# node cast are unknown here, and this node could cast conflicting ones, so
# set-identity refuses to take the identity without it — but only while the bank
# has the Alpenglow genesis certificate, the vote account names the identity being
# set, and it has voted past the genesis slot (should_require_vote_history_file,
# core/src/validator.rs 2233-2270, v4.4.0-rc.1-jito). It does not look at the file when
# there is no certificate yet, when the vote account names another node, or when it
# has not voted past the genesis. The client's refusal reads "Unable to load vote
# history file for identity <pubkey>: <error>. The vote account <vote> has prior
# Alpenglow votes. Ensure the vote history file is present or (dangerous) use
# --do-not-require-vote-history if you know what you're doing" (validator/src/
# admin_rpc_service.rs 1148-1174). The authorized voter goes in before the
# identity, so the identity is never staked while nothing can sign its votes. A
# cold bring-up (the old validator stopped, no process at all; the vote account's
# lastVote stopped changing, two readings 30 s apart agree, and the cluster
# finalized past it) has no vote history to move and says so with
# --do-not-require-vote-history. A hot swap never passes that flag. lastVote is not
# the old node's last vote: under Alpenglow the vote account is written from the
# reward and finalization certificates in the blocks (runtime/src/
# block_component_processor/vote_reward.rs 260-286, 325-337, v4.4.0-rc.1-jito), and the
# block of slot S carries the reward certificate for slot S - NUM_SLOTS_FOR_REWARD,
# 8 (votor-messages/src/reward_certificate.rs 20, core/src/block_creation_loop/
# rewards/certs_builder.rs 95), so lastVote still moves after the old node has
# stopped.
#
# The file keeps changing while the old node votes: its votor rewrites it after
# every vote it casts, a .bin.new written and renamed over it, no fsync (jito-solana
# v4.4.0-rc.1-jito, votor/src/: voting_utils.rs 299-303, vote_history_storage.rs
# 177-191). The rename makes every read a whole file, so a copy taken meanwhile
# loads, and lacks the votes cast after it was read: the votes this node must know.
# The admin RPC changes the identity and only then sends votor a SetIdentity event
# (validator/src/admin_rpc_service.rs 1207-1217), which votor handles later, in its
# own loop (event_handler.rs 548-561, 647-667); from then on it writes the new
# identity's file and not this one, and says so: "set-identity: from <staked> to
# ..." (event_handler.rs 664-667). getIdentity is no sign of that, it answers with
# the new identity before the event is sent. Nor is the first line of that kind in
# the old node's log: an older swap of the same node leaves its own "from <staked>
# to ..." there, with the switch back onto the staked key above it. Step b therefore
# waits until the LATEST set-identity line in that log reads "from <staked> to ...",
# reads the file's sha256 twice, 2 s apart, copies it to a .tmp name in this ledger,
# compares the sha256 with the source's, and only then mv's it into place. The
# ledger sits under SOLANA_HOME, /root/solana by default, and /root
# is 0700 on Ubuntu, so the copy runs through sudo -n at both ends (cat on the old
# node, tee on this one), not through scp. A copy cut short does not load: in a hot
# swap set-identity refuses it (admin_rpc_service.rs 1157-1172); the empty history
# votor takes without a word (event_handler.rs 660-662) is reached only when
# set-identity did not ask for the file (core/src/validator.rs 2233-2270,
# admin_rpc_service.rs 1148-1174).
# Step d reads what votor does with it. votor rewrites the file only after it has
# built a vote (voting_utils.rs 286-303), so a file whose time moves belongs to a
# node that votes. Every try that does not end in a vote is logged as "Failed to
# generate vote message: <why>" (voting_utils.rs 233-263, 265-280, 319): no voter
# in memory (160-162), an identity that is not the rank map's node (195-202, which
# also logs "Rank-map node pubkey mismatch", 197), a voter whose BLS key is not the
# vote account's (204-219, which also logs "No authorized voter keypair matches",
# 217). Until step c is done the node is in one of those states on every try, so
# the log is read backwards, up to its latest set-identity line (event_handler.rs
# 664-667), which must be the switch to <staked>: what is above that line is not the
# swap's. If the latest line is another switch, votor has not handled step c yet; the
# check says so and counts nothing, for the failed tries below an older switch are
# the sync identity's, not the swap's. The log is the one validatorcfg renders
# (--log, lib/validatorcfg.sh
# 338) under the state's solana_home (32), and it is read from there: phase 3 sets
# the global SOLANA_HOME only in the run that executes it (lib/disk.sh 364-369,
# 440), so on install --resume or --only 5 the global is not there, and on the
# data-RAID layout it is not /root/solana (369). The file and the log are root's,
# like the ledger, so step d reads them through sudo -n as well: without it stat and
# tac fail with EACCES, and the check calls a node that votes one that does not.
#
# With no keypair path (offbox mode) step c is the stdin form: the operator pipes
# the key over ssh from the machine that holds it, so it never touches this
# box's disk. sudo -n never prompts: where sudo wants a password it fails
# instead. Without -n the tempting fix, `ssh -tt`, would hand the key to the
# password prompt as typed input. In both modes the swap changes the running
# process only, so a restart of solana comes back on the sync identity.
keys_print_swap_steps() {      # <agave-validator command> <ledger> [<staked keypair>; none = offbox]
    local av=$1 ledger=$2 key=${3:-}
    local vh="${ledger}/vote_history-<staked-pubkey>.bin" log
    log="$(state_get solana_home /root/solana)/solana.log"
    info "     a) OLD validator first — stop voting as staked:"
    info "          agave-validator --ledger <old-ledger> set-identity <old-unstaked-keypair.json>"
    info "        Make sure a restart of the OLD validator comes back unstaked: point its startup"
    info "        --identity (argv or symlink) at the unstaked key, and turn off any failover automation."
    info "     b) Move its vote history here (not a secret). The old node keeps writing it until its voting loop"
    info "        has handled step a: wait for that, then for the file to stop changing, copy it under a"
    info "        temporary name, compare, and move it in (the ledgers are root's: every step runs under sudo -n):"
    info "          ssh <old> 'sudo -n tac <old-log> | grep -m1 \"set-identity: from \" | grep \"from <staked-pubkey> to \"'"
    info "            (this line must print: the old node's latest switch is away from the staked key; if it does not, wait, run it again)"
    info "          ssh <old> 'sudo -n sha256sum <old-ledger>/vote_history-<staked-pubkey>.bin; sleep 2; sudo -n sha256sum <old-ledger>/vote_history-<staked-pubkey>.bin'"
    info "            (the same sha256 twice; if not, the file keeps changing: run it again)"
    info "          ssh <old> 'sudo -n cat <old-ledger>/vote_history-<staked-pubkey>.bin' | ssh <this-box> 'sudo -n tee ${vh}.tmp >/dev/null'"
    info "          ssh <this-box> 'sudo -n sha256sum ${vh}.tmp'      (the same sha256 as the old node's)"
    info "          ssh <this-box> 'sudo -n mv ${vh}.tmp ${vh}'"
    if [[ -n "$key" ]]; then
        info "     c) This box — the voter first, then the identity. set-identity refuses without the vote history"
        info "        while the vote account names this identity and has voted past the Alpenglow genesis:"
        info "          ${av} --ledger ${ledger} authorized-voter add ${key}"
        info "          ${av} --ledger ${ledger} set-identity ${key}"
    else
        info "     c) From the machine that holds the key (staked.json there) — it goes over ssh on stdin"
        info "        and never touches this box's disk. The voter first, then the identity."
        info "        set-identity refuses without the vote history"
        info "        while the vote account names this identity and has voted past the Alpenglow genesis:"
        info "          ssh <this-box> 'sudo -n ${av} --ledger ${ledger} authorized-voter add' < staked.json"
        info "          ssh <this-box> 'sudo -n ${av} --ledger ${ledger} set-identity' < staked.json"
        info "        Keep ssh without -t: the key must reach agave-validator through a pipe, not a terminal."
    fi
    info "        Any restart of solana (crash, reboot, upgrade) brings this node back on the sync"
    info "        identity: it does not vote until you repeat these two commands (the vote history is"
    info "        local by then)."
    info "     d) On this box (offbox mode: log in to it, no key is involved) — within about 15 s of step c, check that it votes:"
    info "          t=\$(sudo -n stat -c %y ${vh}); sleep 15; [ \"\$(sudo -n stat -c %y ${vh})\" != \"\$t\" ] && echo VOTING || echo NOT-VOTING"
    info "          sudo -n tac ${log} | awk '/set-identity: from / {s=1; f = (\$0 ~ / to <staked-pubkey>/); exit} /Failed to generate vote message|No authorized voter keypair matches|Rank-map node pubkey mismatch/ {n++; print} END {print (!s ? \"no set-identity line in the log\" : f ? (n+0) \" such lines after the switch\" : \"the latest set-identity line is not the switch to <staked-pubkey>: wait, run it again\")}'"
    info "        The file must change, and none of those three lines may follow the switch. If not, this node does"
    info "        not vote and the old one has stopped: nobody votes until it is fixed."
    info "     Cold bring-up instead, no vote history: only when the old validator is stopped (no process"
    info "     at all, not just unstaked), the vote account's lastVote has stopped changing (two readings"
    info "     30 s apart agree) and the finalized slot is past it —"
    info "     step c with set-identity --do-not-require-vote-history. Never in a hot swap."
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
