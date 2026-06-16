#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/doublezero.sh   (DoubleZero, optional)
#
# PRINCIPLE: the post-swap step (dz-connect) is MINIMAL — only what genuinely
# needs the staked key + a running node (keypair migration, passport, connect,
# multicast, verify). Everything that does NOT need the staked key is done early,
# in Phase 1, alongside the base system:
#
#   Phase 1 (base.sh, all gated on dz_enabled):
#     * dz_should_enable      — the single early "Enable DoubleZero?" prompt
#     * dz_install_packages   — doublezero + doublezero-solana (mainnet repo)
#     * dz_env_override       — -env mainnet-beta (+metrics), enabled on boot
#     * dz_firewall           — GRE + BGP(179) + 44880/udp
#   Phase 5 (keys.sh):
#     * dz_keypair_check_soft — presence check / reminder (NON-blocking)
#   Phase 6 (validatorcfg.sh):
#     * 2nd shred-receiver-address (233.84.178.1:7733) iff dz_enabled
#   Reboot gate (deeploy.sh):
#     * dz_print_old_server_reminder — early heads-up to free the OLD server
#   dz-connect (this module, the MANUAL post-swap step):
#     * dz_keypair_migrate (HARD) -> find-validator poll -> old-server GATE ->
#       passport -> connect ibrl -> multicast -> latency + status displays
#
# passport requires the validator in Solana gossip AND the leader schedule, which
# is only true AFTER the manual swap to the staked identity — hence connect is a
# separate manual step, never part of the install phase chain.
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
DZ_LATENCY_RETRIES="${DZ_LATENCY_RETRIES:-3}" # device discovery: docs say wait 10-20s + retry
DZ_LATENCY_INTERVAL="${DZ_LATENCY_INTERVAL:-15}"
DZ_LATENCY_TOPN="${DZ_LATENCY_TOPN:-8}"       # show only the N nearest devices (not the ~150-row dump)
# The status display POLLS until BOTH tunnels are "BGP Session Up" — the Multicast
# (doublezero1) BGP session can lag IBRL's (doublezero0) ~1min, so we wait for the
# slower of the two, then warn. (These supersede the old DZ_STATUS_* status-poll vars.)
DZ_MCAST_RETRIES="${DZ_MCAST_RETRIES:-18}"    # ~3 min at 10s for both BGP sessions
DZ_MCAST_INTERVAL="${DZ_MCAST_INTERVAL:-10}"
DZ_PASS_RETRIES="${DZ_PASS_RETRIES:-12}"      # access-pass propagation after request: ~2 min at 10s
DZ_PASS_INTERVAL="${DZ_PASS_INTERVAL:-10}"

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
# OUTPUT we need: doublezero address/status/latency/find-validator). Honors
# dry-run by echoing nothing; mockable by shadowing the underlying command.
run_capture() {
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} $*" >&2; return 0; fi
    "$@"
}

# The DZ keypair path (state > home default). Shared by the soft check + migrate.
_dz_keypair_path() {
    local home; home="$(state_get solana_home /root/solana)"
    printf '%s' "${DZ_KEYPAIR:-$(state_get dz_keypair "$home/dz-keypair.json")}"
}

# Single DZ decision — the EARLY, VISIBLE prompt (called from Phase 1 base.sh,
# alongside the SSH-port prompt). Precedence:
#   env DZ_ENABLED > recorded state > interactive ask (default N) > skip.
# --yes does NOT auto-enable (a tunnel + key migration is never unattended).
# Records dz_enabled to state immediately; every later phase READS that state and
# never re-prompts. Returns 0 if DZ should be set up.
dz_should_enable() {
    local decision
    if [[ -n "${DZ_ENABLED+x}" ]]; then
        decision="$DZ_ENABLED"
    elif [[ -n "$(state_get dz_enabled "")" ]]; then
        decision="$(state_get dz_enabled)"
    elif is_interactive && [[ "${ASSUME_YES:-0}" != "1" ]]; then
        ask "Enable DoubleZero (DZ)? Set up now; connect runs after the staked-key swap. [y/N]" "N"
        case "$REPLY" in [Yy]*) decision=true ;; *) decision=false ;; esac
    else
        decision=false
    fi
    state_set dz_enabled "$decision"
    if [[ "$decision" == "true" ]]; then
        info "DoubleZero ENABLED — have your DoubleZero ID (dz-keypair.json) handy; you'll place it in Phase 5 (Keys)."
        return 0
    fi
    return 1
}

# --- config (used by dz-connect / dz_resume) ---------------------------------
dz_resolve_config() {
    SOLANA_BIN="$(deeploy_solana_bin)"        # $HOME-independent (dz-connect/resume run standalone)
    SOLANA_HOME="$(state_get solana_home /root/solana)"
    DZ_KEYPAIR="$(_dz_keypair_path)"
    STAKED_KEYPAIR="$(state_get staked_keypair "$SOLANA_HOME/mainnet-validator-keypair.json")"
    # client-ip for `connect ibrl`: explicit env > recorded state > auto-detect.
    [[ -z "${DZ_CLIENT_IP:-}" ]] && DZ_CLIENT_IP="$(state_get dz_client_ip "")"
    [[ -z "${DZ_CLIENT_IP:-}" ]] && DZ_CLIENT_IP="$(_dz_detect_public_ip)"
    state_set dz_keypair "$DZ_KEYPAIR"
    [[ -n "$DZ_CLIENT_IP" ]] && state_set dz_client_ip "$DZ_CLIENT_IP"
}

# ============================================================================
# Phase 1 pieces (called from base.sh; gated there on dz_enabled)
# ============================================================================

# Install doublezero + doublezero-solana. Repo-swap aware: an old (e.g. testnet)
# cloudsmith repo is removed first so the mainnet-beta repo/key take over (docs).
dz_install_packages() {
    step "Installing DoubleZero (mainnet-beta cloudsmith repo + apt)"
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would remove any old DZ repo, add ${DZ_SETUP_URL}, then apt-get install doublezero doublezero-solana"
        return 0
    fi
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

# Firewall (official UFW form): GRE + BGP (doublezero0 link-local 179) + 44880/udp.
# The doublezero0-bound rules are added BEFORE the interface exists (it appears at
# connect, post-swap) — ufw accepts interface-bound rules for a not-yet-present
# interface; they activate when doublezero0 comes up.
dz_firewall() {
    step "ufw: GRE + BGP + 44880 for DoubleZero"
    run ufw allow proto gre from any to any
    run ufw allow in  on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
    run ufw allow out on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp
    run ufw allow in  on doublezero0 to any port 44880 proto udp
    run ufw allow out on doublezero0 to any port 44880 proto udp
}

# ============================================================================
# Phase 5 piece — SOFT presence check (called from keys.sh; NON-blocking)
# ============================================================================
# Just confirm the DZ ID is on disk (or copy a given path to the standard path)
# and remind. Never blocks Phase 5 — there's a reboot + staked-key swap before
# dz-connect, so the operator has a window to place it. The HARD check is in
# dz-connect (dz_keypair_migrate).
dz_keypair_check_soft() {
    [[ "$(state_get dz_enabled false)" == "true" ]] || return 0
    step "DoubleZero ID presence check (soft)"
    local kp; kp="$(_dz_keypair_path)"
    state_set dz_keypair "$kp"
    if [[ -f "$kp" ]]; then ok "DoubleZero ID present at ${kp}"; return 0; fi
    if is_interactive; then
        warn "No DoubleZero ID at ${kp} yet."
        info "Place your DoubleZero ID at ${kp}, or give a path to it now (it'll be copied there)."
        ask "DoubleZero ID path (or place it at ${kp} then press Enter; blank to defer)" "$kp"
        local src="$REPLY"
        if [[ -n "$src" && -f "$src" && "$src" != "$kp" ]]; then
            run install -m 600 "$src" "$kp" && ok "Copied DoubleZero ID to ${kp}"
        fi
    fi
    [[ -f "$kp" ]] || warn "DoubleZero ID still not at ${kp} — place it before '${DEEPLOY_CMD} dz-connect' (dz-connect REQUIRES it). Continuing for now."
    return 0
}

# ============================================================================
# Reboot-gate piece — early old-server reminder (called from deeploy.sh)
# ============================================================================
# The exact commands the operator runs ON THE OLD SERVER to free the DZ ID. Only
# the OLD server can disconnect itself (DeePloy can't reach it). Shared by the
# early reminder + the blocking gate so both print identically.
_dz_old_server_commands() {
    info "    On the OLD server, run:"
    info "        doublezero disconnect"
    info "        sudo systemctl stop doublezerod"
    info "        sudo systemctl disable doublezerod"
}

dz_print_old_server_reminder() {
    step "DoubleZero: disconnect the OLD server before the swap"
    warn "Your DoubleZero ID is the SAME one currently active on your OLD server."
    info "Before you swap the staked key and run '${DEEPLOY_CMD} dz-connect', disconnect DoubleZero"
    info "on the OLD server — the same DZ ID can't be active on two machines at once:"
    _dz_old_server_commands
}

# ============================================================================
# Phase 7 (install) — no-op pointer (prepare already happened in Phase 1)
# ============================================================================
doublezero_run() {
    require_root
    step "DoubleZero (prepared in Phase 1)"
    info "Package, env, and firewall were set up in Phase 1. Connect is a manual"
    info "post-swap step. After the node reaches 'catchup 0' and you swap to the"
    info "staked identity, run:"
    info "    ${DEEPLOY_CMD} dz-connect"
    info "  (migrates the DZ ID, polls gossip/leader-schedule, then passport + connect ibrl + multicast)"
}

# ============================================================================
# dz-connect — the MANUAL post-swap step (Path 1, primary only)
# ============================================================================

# HARD keypair migration: install the DZ ID to ~/.config/doublezero/id.json and
# validate with `doublezero address`. Blocks/loops until a valid key is present
# (passport cannot proceed without it); non-interactive absent -> fail.
dz_keypair_migrate() {
    step "DoubleZero ID migration -> ${DZ_CONFIG_DIR}/id.json"
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
            fail "DoubleZero ID absent at ${DZ_KEYPAIR} and run is non-interactive. Place it (chmod 600) and re-run '${DEEPLOY_CMD} dz-connect'."
        fi
        if [[ -n "$src" && -f "$src" ]]; then
            run install -m 600 "$src" "$DZ_CONFIG_DIR/id.json"
            [[ "$src" != "$DZ_KEYPAIR" ]] && run install -m 600 "$src" "$DZ_KEYPAIR"   # keep the canonical copy too
            addr="$(_dz_address)"
            if [[ -n "$addr" ]]; then
                ok "DoubleZero ID installed (${addr})"
                state_set dz_id "$addr"
                return 0
            fi
            warn "Installed key at ${DZ_CONFIG_DIR}/id.json but 'doublezero address' returned nothing — not a valid DZ ID?"
        else
            warn "No file at '${src:-<empty>}'."
        fi
        # loop and re-prompt (interactive only; non-interactive already failed)
    done
}

# Poll passport find-validator until the validator is in gossip AND the leader
# schedule (the 5-10 min post-swap window).
_dz_await_in_leader_schedule() {
    local i out in_sched
    have jq || fail "jq is required to parse 'doublezero-solana passport find-validator' output but is not installed (it is a base package — re-run Phase 1)."
    for ((i=1; i<=DZ_FIND_RETRIES; i++)); do
        # --json-compact gives a clean boolean. The HUMAN text is polarity-blind:
        # both the positive ("...leader scheduled validator.") and the negative
        # ("...not leader scheduled...") contain "leader schedul", and ✅ shows for a
        # backup too — so neither the label nor the checkmark is a usable anchor.
        # Parse in_leader_schedule and fail CLOSED: anything not exactly true
        # (false / empty / invalid JSON) keeps polling, never proceeds. (R16/F1)
        out="$(run_capture doublezero-solana passport find-validator -u "$DZ_ENV" --json-compact 2>&1 || true)"
        in_sched="$(jq -r '.in_leader_schedule // false' <<<"$out" 2>/dev/null || echo false)"
        if [[ "$in_sched" == "true" ]]; then
            ok "Validator is in gossip + leader schedule (primary-eligible)"
            return 0
        fi
        info "Waiting for the validator to appear in gossip + leader schedule (attempt ${i}/${DZ_FIND_RETRIES}, ~${DZ_FIND_INTERVAL}s)…"
        sleep "$DZ_FIND_INTERVAL"
    done
    fail "Validator never reached in_leader_schedule=true after $((DZ_FIND_RETRIES * DZ_FIND_INTERVAL))s — it can connect only as a backup, or the staked-key swap/voting hasn't propagated yet. Confirm the node is voting, then re-run '${DEEPLOY_CMD} dz-connect'."
}

# Blocking gate, before this machine connects (the moment the DZ ID goes live).
# The same ID active on two machines conflicts; only the OLD server can
# disconnect itself. Explicit acknowledgment; does NOT honor --yes (a conflict
# guard, like require_yes); fails clearly non-interactively.
dz_confirm_old_server_disconnected() {
    step "Before connecting: the OLD server must be disconnected"
    warn "The same DoubleZero ID active on two machines at once WILL conflict."
    info "Confirm DoubleZero is disconnected on your OLD server first."
    _dz_old_server_commands
    if ! is_interactive; then
        fail "Cannot confirm the OLD server is disconnected in a non-interactive run. On the OLD server run 'doublezero disconnect' (then stop/disable doublezerod), then re-run '${DEEPLOY_CMD} dz-connect'."
    fi
    # Robust interactive read: trim whitespace, take the LAST token (so backspace
    # artifacts / a stray char-then-correction don't poison the answer), match
    # strictly y/n. RE-PROMPT on anything else — a typo must not abort dz-connect.
    # Still ignores --yes (this is a safety gate, like require_yes). An explicit
    # 'n'/'no' fails (operator says the old server is NOT yet disconnected).
    # Match the WHOLE trimmed reply strictly (NOT the last token of a phrase — a
    # safety gate must never auto-proceed on an ambiguous multi-word answer like
    # "maybe y"). Trim surrounding whitespace, then: y/yes -> proceed; n/no ->
    # fail; empty -> fail (closed); anything else (typo, phrase) -> RE-PROMPT so a
    # mistype doesn't abort dz-connect. Terminates on EOF (read fails -> "" -> fail).
    local reply ans
    while true; do
        printf '%s  Has the OLD server been disconnected (doublezerod stopped)?%s [y/N]: ' "$C_BOLD" "$C_NC"
        read -r reply || reply=""
        ans="${reply#"${reply%%[![:space:]]*}"}"   # ltrim leading whitespace
        ans="${ans%"${ans##*[![:space:]]}"}"        # rtrim trailing whitespace
        case "$ans" in
            [Yy]|[Yy][Ee][Ss]) ok "Acknowledged — proceeding to connect this machine."; return 0 ;;
            [Nn]|[Nn][Oo]|"")  fail "Disconnect DoubleZero on the OLD server first, then re-run '${DEEPLOY_CMD} dz-connect'." ;;
            *) warn "Please answer y or n." ;;     # typo/phrase -> re-prompt, don't abort, never auto-proceed
        esac
    done
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

# Run a `doublezero connect ...` with a bounded retry ONLY on the access-pass
# propagation race: request-validator-access submits the on-chain request, but the
# resulting Access Pass isn't immediately visible to `connect` (~1 min lag, seen
# on-box). Retry specifically on "Access Pass not found"; ANY other connect error
# fails FAST so a real failure is never masked. On exhausted retries, fail with an
# actionable message (the request was submitted; re-run dz-connect — idempotent). (F2)
_dz_connect_with_retry() {
    local i out
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} $*"; return 0; fi
    for ((i=1; i<=DZ_PASS_RETRIES; i++)); do
        if out="$("$@" 2>&1)"; then
            [[ -n "$out" ]] && printf '%s\n' "$out"
            return 0
        fi
        if grep -qi 'Access Pass not found' <<<"$out"; then
            info "Access Pass not yet propagated — retrying connect (attempt ${i}/${DZ_PASS_RETRIES}, ~${DZ_PASS_INTERVAL}s)…"
            sleep "$DZ_PASS_INTERVAL"
            continue
        fi
        [[ -n "$out" ]] && printf '%s\n' "$out" >&2
        fail "DoubleZero connect failed ('$*') — not an access-pass race, so not retried. See the error above."
    done
    fail "DoubleZero Access Pass never propagated after $((DZ_PASS_RETRIES * DZ_PASS_INTERVAL))s. The access request WAS submitted; wait ~1 min and re-run '${DEEPLOY_CMD} dz-connect' (it is idempotent — request is a no-op, connect picks up the pass)."
}

dz_connect_ibrl() {
    step "DoubleZero connect ibrl (client-ip ${DZ_CLIENT_IP:-auto})"
    if [[ -n "${DZ_CLIENT_IP:-}" ]]; then _dz_connect_with_retry doublezero connect ibrl --client-ip "$DZ_CLIENT_IP"
    else _dz_connect_with_retry doublezero connect ibrl; fi
}

dz_multicast_publish() {
    step "DoubleZero multicast publish (edge-solana-shreds)"
    # No validator restart: the multicast shred-address is already in validator.sh
    # (Phase 6, gated on dz_enabled) and is picked up live.
    _dz_connect_with_retry doublezero connect multicast --publish edge-solana-shreds
}

# --- verification displays (end of dz-connect) -------------------------------

# Parse `doublezero latency` (Pubkey|Code|IP|Min|Max|Avg|reachable): emit the
# nearest device "CODE AVG" (lowest Avg). Columns found by header name so extra/
# elided columns don't matter.
_dz_parse_latency_nearest() {
    awk -F'|' '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
        /[Cc]ode/ && /[Aa]vg/ { for(i=1;i<=NF;i++){h=trim($i); if(h=="Code")cc=i; if(h=="Avg")ac=i} hdr=1; next }
        hdr && cc && ac {
            code=trim($cc); avg=trim($ac); sub(/ *ms$/,"",avg)
            if(code=="" || avg !~ /^[0-9]+(\.[0-9]+)?$/) next   # require a real number (not "." / "...")
            if(best=="" || avg+0 < best+0){ best=avg; bc=code }
        }
        END { if(bc!="") printf "%s %s", bc, best }
    '
}

# Emit the N nearest "CODE  AVGms" lines (lowest Avg first) — the table can be
# ~150 rows; we only want the closest few. N defaults to DZ_LATENCY_TOPN.
_dz_parse_latency_topn() {
    local n=${1:-8}
    [[ "$n" =~ ^[0-9]+$ ]] || n=8     # non-numeric N (misconfig) -> default, not a whole-table dump
    awk -F'|' -v n="$n" '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
        BEGIN { n=n+0 }                # force numeric so the k<=n guard is numeric, not lexicographic
        /[Cc]ode/ && /[Aa]vg/ { for(i=1;i<=NF;i++){h=trim($i); if(h=="Code")cc=i; if(h=="Avg")ac=i} hdr=1; next }
        hdr && cc && ac {
            code=trim($cc); avg=trim($ac); sub(/ *ms$/,"",avg)
            if(code=="" || avg !~ /^[0-9]+(\.[0-9]+)?$/) next   # require a real number
            codes[++m]=code; avgs[m]=avg+0
        }
        END {
            # simple selection of the n smallest by avg
            for(k=1;k<=n && k<=m;k++){
                mi=0
                for(j=1;j<=m;j++) if(!used[j] && (mi==0 || avgs[j]<avgs[mi])) mi=j
                if(mi==0) break
                used[mi]=1
                printf "    %-14s %sms\n", codes[mi], avgs[mi]
            }
        }
    '
}

dz_show_latency() {
    step "DoubleZero device latency (nearest devices)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would run 'doublezero latency' and show the ${DZ_LATENCY_TOPN} nearest devices"; return 0; fi
    local out i nearest topn
    for ((i=1; i<=DZ_LATENCY_RETRIES; i++)); do
        out="$(run_capture doublezero latency 2>/dev/null || true)"
        [[ -n "$out" && "$out" =~ [0-9] ]] && break
        info "No DZ devices yet (attempt ${i}/${DZ_LATENCY_RETRIES}) — waiting ${DZ_LATENCY_INTERVAL}s…"
        sleep "$DZ_LATENCY_INTERVAL"
    done
    # Show ONLY the nearest N (the full table is ~150 rows of noise).
    topn="$(printf '%s\n' "$out" | _dz_parse_latency_topn "$DZ_LATENCY_TOPN")"
    if [[ -n "$topn" ]]; then
        info "Nearest ${DZ_LATENCY_TOPN} DZ devices (by avg latency):"
        printf '%s\n' "$topn"
    else
        warn "Could not parse the 'doublezero latency' table — raw output:"
        printf '%s\n' "$out" | head -20 | sed 's/^/    /'
    fi
    nearest="$(printf '%s\n' "$out" | _dz_parse_latency_nearest)"
    if [[ -n "$nearest" ]]; then ok "Nearest DZ device: ${nearest%% *} (avg ${nearest##* }ms)"
    else warn "Could not determine the nearest DZ device from 'doublezero latency'"; fi
}

# Extract one field from the `doublezero status` table: the value of column
# <header> in the row whose "Tunnel Name" == <tunnel>. Pipe-delimited; columns
# found by header name (robust to elided/extra columns).
_dz_status_field() {
    local wt=$1 wc=$2
    awk -F'|' -v wt="$wt" -v wc="$wc" '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
        /Tunnel Name/ && /Tunnel Status/ { for(i=1;i<=NF;i++) c[trim($i)]=i; tn=c["Tunnel Name"]; tc=c[wc]; hdr=1; next }
        hdr && tn && tc { if(trim($tn)==wt){ print trim($tc); exit } }
    '
}

# Poll `doublezero status` until BOTH tunnels reach "BGP Session Up". IBRL
# (doublezero0) comes up in ~1min; the Multicast (doublezero1) BGP session can
# lag a bit longer (the operator saw it "Pending BGP Session" right after connect
# while IBRL was already up). So we keep polling up to DZ_MCAST_RETRIES×INTERVAL
# (~3 min) for the SECOND session, and only warn if it's still pending after that
# — rather than snapshotting once immediately after connect. Then display both.
dz_show_status() {
    step "DoubleZero status (tunnels)"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would poll 'doublezero status' until both tunnels are BGP Session Up"; return 0; fi
    local out i ibrl mcast
    for ((i=1; i<=DZ_MCAST_RETRIES; i++)); do
        out="$(run_capture doublezero status 2>&1 || true)"
        ibrl="$(printf '%s\n' "$out"  | _dz_status_field doublezero0 'Tunnel Status')"
        mcast="$(printf '%s\n' "$out" | _dz_status_field doublezero1 'Tunnel Status')"
        # Both up -> done. (Multicast row may be absent until it initializes.)
        if [[ "$ibrl" == *"BGP Session Up"* && "$mcast" == *"BGP Session Up"* ]]; then break; fi
        info "Waiting for both tunnels up (attempt ${i}/${DZ_MCAST_RETRIES}, ~${DZ_MCAST_INTERVAL}s) — IBRL='${ibrl:-?}' Multicast='${mcast:-pending}'…"
        sleep "$DZ_MCAST_INTERVAL"
    done
    printf '%s\n' "$out" | sed 's/^/    /'
    local device metro mgroup
    ibrl="$(printf '%s\n' "$out"   | _dz_status_field doublezero0 'Tunnel Status')"
    mcast="$(printf '%s\n' "$out"  | _dz_status_field doublezero1 'Tunnel Status')"
    device="$(printf '%s\n' "$out" | _dz_status_field doublezero0 'Current Device')"
    metro="$(printf '%s\n' "$out"  | _dz_status_field doublezero0 'Metro')"
    mgroup="$(printf '%s\n' "$out" | _dz_status_field doublezero1 'Multicast Groups')"
    info "  IBRL (doublezero0):      ${ibrl:-?}   device=${device:-?}  metro=${metro:-?}"
    info "  Multicast (doublezero1): ${mcast:-?}   groups=${mgroup:-?}"
    if [[ "$ibrl" == *"BGP Session Up"* && "$mcast" == *"BGP Session Up"* && "$mgroup" == *edge-solana-shreds* ]]; then
        ok "DZ connected — IBRL via ${device} (${metro}), publishing shreds to edge-solana-shreds."
    elif [[ "$ibrl" == *"BGP Session Up"* && "$mcast" != *"BGP Session Up"* ]]; then
        warn "IBRL is up (via ${device:-?}/${metro:-?}) but the Multicast BGP session is still '${mcast:-pending}' after ~$((DZ_MCAST_RETRIES * DZ_MCAST_INTERVAL))s. It often comes up shortly after — re-check with 'doublezero status'; if it stays pending, re-run '${DEEPLOY_CMD} dz-connect'."
    else
        warn "DZ not fully up — IBRL='${ibrl:-?}' Multicast='${mcast:-?}' groups='${mgroup:-?}'. Inspect 'doublezero status'."
    fi
}

dz_connect_run() {
    require_root
    dz_resolve_config
    # Guard: enabled + the binaries are actually installed (Phase 1) + the staked
    # key is in place (post-swap). The binaries check replaces what dz_prepared
    # used to guarantee implicitly — a direct command-present check is reliable.
    [[ "$(state_get dz_enabled false)" == "true" ]] || fail "DoubleZero is not enabled (dz_enabled != true) — nothing to connect."
    have doublezero        || fail "DoubleZero was enabled but 'doublezero' is not installed — re-run install (Phase 1 installs it) or check Phase 1."
    have doublezero-solana || fail "DoubleZero was enabled but 'doublezero-solana' is not installed — re-run install (Phase 1) or check Phase 1."
    [[ -f "$STAKED_KEYPAIR" ]] || fail "Staked key not at ${STAKED_KEYPAIR}. Complete the manual set-identity swap before '${DEEPLOY_CMD} dz-connect'."

    dz_keypair_migrate                         # HARD: mkdir + move + validate (blocks/loops if absent)
    local dz_id staked_id
    dz_id="$(state_get dz_id "")"; [[ -z "$dz_id" ]] && dz_id="$(_dz_address)"
    [[ -n "$dz_id" ]] || fail "Could not determine the DoubleZero ID (doublezero address)."
    staked_id="$(_dz_staked_pubkey "$STAKED_KEYPAIR")"   # intentional staked-key read (passport needs it) — ONLY here
    [[ -n "$staked_id" ]] || fail "Could not read the staked validator pubkey from ${STAKED_KEYPAIR}"

    _dz_await_in_leader_schedule               # the 5-10 min gossip/leader-schedule window
    dz_confirm_old_server_disconnected         # blocking gate BEFORE passport/connect
    dz_passport "$dz_id" "$staked_id"
    dz_connect_ibrl
    dz_multicast_publish
    dz_show_latency                            # verification display: nearest device
    dz_show_status                             # verification display: both tunnels + verdict
    state_set dz_connected "$(_ts)"
    ok "DoubleZero connect complete."
}

# ============================================================================
# Post-reboot resume — gated on dz_connected (NOT dz_enabled): only a tunnel that
# was actually connected (dz-connect ran) can be verified/restored. On the
# isolation reboot — which happens BEFORE dz-connect (connect is post-swap, after
# catchup) — dz_connected is unset, so this correctly no-ops.
# ============================================================================
_dz_iface_up() { ip link show doublezero0 >/dev/null 2>&1; }

dz_resume() {
    require_root
    if [[ "$(state_get dz_connected "")" == "" ]]; then
        info "DoubleZero not yet connected (run '${DEEPLOY_CMD} dz-connect' after the swap) — nothing to restore."
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
