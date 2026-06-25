#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/config.sh   (deeploy export | import)
# Round-trips the unified deeploy.conf so an identical box reproduces without
# re-typing. The conf is bash-env (sectioned, commented, chmod 600) and holds
# PATHS, PUBKEYS, and SETTINGS ONLY — NEVER key material.
#
# export: read the phases' recorded decisions (state) -> write deeploy.conf.
# import: validate (no key material; required keys; pubkey format) -> load into
#         state so the install resolve-functions pick them up. The stored region
#         is reproduced deterministically; `import --rescore` re-pings to refresh
#         BAM/block-engine/shred instead.
#
# Requires: common.sh sourced (region.sh for --rescore). Path overridable.
# ============================================================================

[[ -n "${_DEEPLOY_CONFIG_SOURCED:-}" ]] && return 0
_DEEPLOY_CONFIG_SOURCED=1

config_resolve() { CONFIG_FILE="${CONFIG_FILE:-${DEEPLOY_CONF:-/opt/deeploy/deeploy.conf}}"; }

# Canonical map. "@ <Section>" lines become comment headers; "CONF_KEY state_key"
# lines map an UPPERCASE conf key to its lowercase state key. NO key material.
_config_keys() {
    cat <<'MAP'
@ Network and SSH
SSH_PORT ssh_port
@ CPU tuning
POH_CORE poh_core
XDP_CORES_COUNT xdp_cores_count
XDP_CORES xdp_cores
ISOLATED_SET isolated_set
@ NIC / retransmit
NIC_DRIVER nic_driver
RETRANSMIT_SUPPORTED retransmit_supported
RETRANSMIT_ZERO_COPY retransmit_zero_copy
@ Disk
DISK_LAYOUT disk_layout
LEDGER_DISK ledger_disk
ACCOUNTS_DISK accounts_disk
SOLANA_HOME solana_home
LEDGER_PATH ledger_path
ACCOUNTS_PATH accounts_path
SNAPSHOTS_PATH snapshots_path
@ Build
JITO_TAG jito_tag
@ Keys (PATHS ONLY — no key material; vote is a public pubkey)
UNSTAKED_KEYPAIR sync_identity
STAKED_KEYPAIR staked_keypair
VOTE_ACCOUNT_PUBKEY vote_account_pubkey
@ MEV
MEV_MODE mev_mode
BAM_URL bam_url
BLOCK_ENGINE_URL block_engine_url
SHRED_RECEIVER_ADDRESS shred_receiver
COMMISSION_BPS commission_bps
RELAYER_URL relayer_url
@ Validator network (advanced; usually auto/default — env or conf override)
GOSSIP_PORT gossip_port
RPC_PORT rpc_port
RPC_BIND_ADDRESS rpc_bind_address
RPC_THREADS rpc_threads
DYNAMIC_PORT_RANGE dynamic_port_range
@ Validator runtime / snapshots (advanced; usually default — env or conf override)
REPLAY_THREADS replay_threads
LIMIT_LEDGER_SIZE limit_ledger_size
MIN_SNAPSHOT_DOWNLOAD_SPEED min_snapshot_download_speed
FULL_SNAPSHOT_INTERVAL_SLOTS full_snapshot_interval_slots
INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS incremental_snapshot_interval_slots
@ DoubleZero
DZ_ENABLED dz_enabled
DZ_ENV dz_env
DZ_KEYPAIR dz_keypair
MAP
}

# ============================================================================
# Typed, source-free config parsing (S2).  The conf is DATA, never code: no
# value is ever sourced, eval'd, or executed. Each whitelisted key has a type;
# values are extracted by regex and validated against that type before they are
# allowed to set a global. Anything unknown, empty, or type-invalid is ignored
# or rejected — fail-closed.
# ============================================================================

# CONF_KEY -> type. SINGLE SOURCE OF TRUTH for the typed whitelist; kept in
# lockstep with _config_keys (enforced by the sync test in test_config.sh).
_config_key_types() {
    cat <<'TYPES'
SSH_PORT port
POH_CORE int
XDP_CORES_COUNT int
XDP_CORES cores
ISOLATED_SET cores
NIC_DRIVER word
RETRANSMIT_SUPPORTED flag
RETRANSMIT_ZERO_COPY flag
DISK_LAYOUT word
LEDGER_DISK path
ACCOUNTS_DISK path
SOLANA_HOME path
LEDGER_PATH path
ACCOUNTS_PATH path
SNAPSHOTS_PATH path
JITO_TAG tag
UNSTAKED_KEYPAIR path
STAKED_KEYPAIR path
VOTE_ACCOUNT_PUBKEY pubkey
MEV_MODE mev
BAM_URL url
BLOCK_ENGINE_URL url
SHRED_RECEIVER_ADDRESS hostport
COMMISSION_BPS int
RELAYER_URL url
GOSSIP_PORT port
RPC_PORT port
RPC_BIND_ADDRESS ip
RPC_THREADS int
DYNAMIC_PORT_RANGE portrange
REPLAY_THREADS int
LIMIT_LEDGER_SIZE int
MIN_SNAPSHOT_DOWNLOAD_SPEED int
FULL_SNAPSHOT_INTERVAL_SLOTS int
INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS int
DZ_ENABLED bool
DZ_ENV word
DZ_KEYPAIR path
TYPES
}

# Echo the type for <CONF_KEY>, or nothing if the key is not whitelisted.
_config_key_type() {
    local want=$1 k t
    while read -r k t; do
        [[ "$k" == "$want" ]] && { printf '%s' "$t"; return 0; }
    done < <(_config_key_types)
    return 0
}

# --- per-type validators (fail-closed; anchored). port/pubkey reuse the same
#     helpers the phases use (base.sh / keys.sh) so there is one definition. ---
_cfg_t_path()      { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]; }
_cfg_t_pubkey()    { _keys_valid_pubkey "$1"; }
_cfg_t_port()      { _valid_port "$1"; }
_cfg_t_portrange() { [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] \
                     && _valid_port "${BASH_REMATCH[1]}" && _valid_port "${BASH_REMATCH[2]}" \
                     && (( 10#${BASH_REMATCH[1]} < 10#${BASH_REMATCH[2]} )); }
_cfg_t_cores()     { [[ "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; }
_cfg_t_int()       { [[ "$1" =~ ^[0-9]+$ ]]; }
_cfg_t_bool()      { [[ "$1" =~ ^(true|false)$ ]]; }
_cfg_t_flag()      { [[ "$1" =~ ^[01]$ ]]; }
_cfg_t_url()       { [[ "$1" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; }
_cfg_t_hostport()  { [[ "$1" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; }
_cfg_t_tag()       { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
_cfg_t_word()      { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
_cfg_t_mev()       { [[ "$1" =~ ^(bam|relayer)$ ]]; }
_cfg_t_ip()        { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# _cfg_validate_type <type> <value> -> 0 if valid, 1 otherwise (unknown type = fail).
_cfg_validate_type() {
    case "$1" in
        path)      _cfg_t_path      "$2" ;;
        pubkey)    _cfg_t_pubkey    "$2" ;;
        port)      _cfg_t_port      "$2" ;;
        portrange) _cfg_t_portrange "$2" ;;
        cores)     _cfg_t_cores     "$2" ;;
        int)       _cfg_t_int       "$2" ;;
        bool)      _cfg_t_bool      "$2" ;;
        flag)      _cfg_t_flag      "$2" ;;
        url)       _cfg_t_url       "$2" ;;
        hostport)  _cfg_t_hostport  "$2" ;;
        tag)       _cfg_t_tag       "$2" ;;
        word)      _cfg_t_word      "$2" ;;
        mev)       _cfg_t_mev       "$2" ;;
        ip)        _cfg_t_ip        "$2" ;;
        *)         return 1 ;;
    esac
}

# _config_parse_safe <file>
# Parse KEY=value lines WITHOUT sourcing. Sets the UPPERCASE globals for every
# whitelisted, non-empty, type-valid value (via `printf -v`, never eval). The
# value is extracted by regex (quoted form first, then an unquoted fallback that
# stops at whitespace/#), so $(...), backticks, ;, spaces and newlines can never
# be executed — they only ever fail their type regex. Returns 1 (naming the
# offending keys) if any whitelisted value is type-invalid; 0 otherwise.
_config_parse_safe() {
    local file=$1
    [[ -f "$file" ]] || { warn "config not found: $file"; return 1; }
    local line key val t errs=""
    # quoted:   KEY="value"   (anything after the closing quote — trailing
    #           whitespace / inline # comment — is ignored, matching the
    #           quote-aware _config_validate)
    # unquoted: KEY=value     (value stops at the first whitespace, # or quote)
    local qre='^[[:space:]]*([A-Z][A-Z0-9_]*)="([^"]*)"'
    local ure='^[[:space:]]*([A-Z][A-Z0-9_]*)=([^[:space:]#"]*)'
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue          # blank / comment
        if   [[ "$line" =~ $qre ]]; then key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $ure ]]; then key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        else continue
        fi
        t="$(_config_key_type "$key")"
        [[ -z "$t"   ]] && { debug "config: ignoring non-whitelisted key $key"; continue; }
        [[ -z "$val" ]] && { debug "config: skipping empty $key (preserves default)"; continue; }   # P2
        if _cfg_validate_type "$t" "$val"; then
            printf -v "$key" '%s' "$val"                          # set global WITHOUT eval
        else
            errs+=" $key"
            warn "config: rejecting $key — not a valid ${t}"
        fi
    done < "$file"
    if [[ -n "$errs" ]]; then
        warn "config: ${file} has invalid value(s):${errs} — not applied"
        return 1
    fi
    return 0
}

# --- export ------------------------------------------------------------------
config_export() {
    config_resolve
    # Bridge a global into state so it's captured too.
    [[ -n "${DZ_ENABLED:-}" ]]  && state_set dz_enabled "$DZ_ENABLED"

    local content a b v ver header_pending=""
    ver="$(state_get deeploy_version "$DEEPLOY_VERSION")"
    content="# DeePloy config — generated by '${DEEPLOY_CMD} export' ($(date -u '+%Y-%m-%d %H:%M:%S')Z)
# Created with DeePloy v${ver}
# PATHS, PUBKEYS, and SETTINGS only — NEVER key material. chmod 600.
# Reuse on an identical box:  ${DEEPLOY_CMD} install --config <this file>
"
    while read -r a b; do
        [[ -z "$a" ]] && continue
        # Buffer the section header; emit it only when a non-empty key follows,
        # so an all-empty section leaves no dangling header.
        if [[ "$a" == "@" ]]; then header_pending=$'\n'"# --- ${b} ---"$'\n'; continue; fi
        v="$(state_get "$b" "")"
        [[ -z "$v" ]] && continue                 # P2: skip empty -> no KEY="" clobber on re-import
        [[ -n "$header_pending" ]] && { content+="$header_pending"; header_pending=""; }
        content+="${a}=\"${v}\""$'\n'
    done < <(_config_keys)

    write_file "$CONFIG_FILE" "$content" 0600
    ok "Exported config -> ${CONFIG_FILE} (paths/pubkeys/settings only; chmod 600)"
}

# --- validate (before acting) ------------------------------------------------
_config_validate() {
    local f=$1 k vote
    [[ -f "$f" ]] || { warn "config not found: $f"; return 1; }
    # Refuse anything that looks like embedded key material (a keypair is a JSON
    # array of ints, e.g. [174,12,...]).
    if grep -qE '\[[0-9]+,[0-9]+' "$f"; then
        warn "Refusing import: $f appears to contain key material (a JSON int array). Configs must hold PATHS ONLY."
        return 1
    fi
    for k in JITO_TAG SOLANA_HOME VOTE_ACCOUNT_PUBKEY; do
        grep -qE "^${k}=" "$f" || { warn "config missing required key: ${k}"; return 1; }
    done
    vote=$(awk -F'"' '/^VOTE_ACCOUNT_PUBKEY=/{print $2; exit}' "$f")
    [[ "$vote" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { warn "VOTE_ACCOUNT_PUBKEY not a valid base58 pubkey: '${vote}'"; return 1; }
    return 0
}

# --- import ------------------------------------------------------------------
config_import() {
    config_resolve
    _config_validate "$CONFIG_FILE" || fail "Config validation failed — nothing imported"
    # Parse, NEVER source: a poisoned conf must not execute as root (S2).
    _config_parse_safe "$CONFIG_FILE" || fail "Config parse failed (invalid value) — nothing imported"
    local a b v
    while read -r a b; do
        [[ -z "$a" || "$a" == "@" ]] && continue
        v="${!a:-}"                       # value of the UPPERCASE conf global
        [[ -n "$v" ]] && state_set "$b" "$v"
    done < <(_config_keys)

    if [[ "${RESCORE:-0}" == "1" ]]; then
        if declare -F region_recommend >/dev/null; then
            info "Re-scoring region (import --rescore) — re-pinging BAM + block-engine..."
            region_recommend || warn "region scan failed — keeping stored region"
            state_set bam_url          "$(state_get suggested_bam_url "$(state_get bam_url)")"
            state_set block_engine_url "$(state_get suggested_block_engine_url "$(state_get block_engine_url)")"
            state_set shred_receiver   "$(state_get suggested_shred_receiver "$(state_get shred_receiver)")"
        else
            warn "region.sh not loaded — cannot rescore; keeping stored region"
        fi
    else
        info "Reproducing stored region deterministically: $(state_get bam_url '<none>')  (use 'import --rescore' to re-ping)"
    fi
    ok "Imported config from ${CONFIG_FILE} into state"
}
