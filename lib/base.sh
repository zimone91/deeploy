#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/base.sh   (Phase 1: base system)
# Packages, SSH-port change (with verify-or-rollback so a bad change can never
# lock the operator out), and the core validator firewall.
#
# Firewall scope: this module owns the core validator rules and, when DoubleZero
# is enabled, calls doublezero.sh's dz_firewall (GRE/BGP/44880) so ALL firewall
# rules are configured in one place. The DZ rule bodies live in doublezero.sh;
# relayer/shred ports live in relayer.sh.
#
# DoubleZero in Phase 1: the single "Enable DoubleZero?" prompt (dz_should_enable),
# package install (dz_install_packages + dz_env_override), and firewall
# (dz_firewall) all happen here — everything that does NOT need the staked key.
# Connect is the post-swap 'deeploy dz-connect'. All DZ calls are declare-F
# guarded + dz_enabled gated, so base.sh stays sourceable/testable on its own.
#
# Requires: common.sh sourced. All mutations go through run()/ensure_*/backup_*,
# so --dry-run prints the plan and changes nothing.
# ============================================================================

[[ -n "${_DEEPLOY_BASE_SOURCED:-}" ]] && return 0
_DEEPLOY_BASE_SOURCED=1

# Whether to run `apt-get upgrade` (a fresh box benefits; reboot in Phase 2
# absorbs any kernel update). Override with BASE_APT_UPGRADE=false.
BASE_APT_UPGRADE="${BASE_APT_UPGRADE:-true}"

# The operator's proven apt set (from the install guide), verbatim.
BASE_PACKAGES=(
    sshpass nload rsync cpufrequtils moreutils ntp ufw hwloc
    software-properties-common aptitude git curl lm-sensors liblz4-tool zip unzip
    jq wget nano htop smartmontools tmux net-tools bash-completion pciutils ethtool
    mc python3 python3-dev python3-virtualenv python3-venv libffi-dev
    apt-transport-https tzdata ca-certificates build-essential libboost-all-dev
    automake autoconf pkg-config libcurl4-openssl-dev libjansson-dev libssl-dev
    libgmp-dev make autotools-dev libtool psmisc bsdmainutils libminiupnpc-dev
    libevent-dev cmake screen atop ncdu fail2ban
)

# --- helpers -----------------------------------------------------------------
_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# Echo the active (uncommented) Port from sshd_config, or empty.
_sshd_configured_port() {
    local cfg=$1
    [[ -f "$cfg" ]] || return 0
    awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{p=$2} END{if(p) print p}' "$cfg"
}

# N5 (read side): the port(s) sshd will ACTUALLY listen on, one per line.
# `sshd -T` is authoritative — it resolves the default (a commented '#Port 22'
# is an effective 22), catches MULTIPLE Port directives, and sees Include
# drop-ins (Ubuntu 24.04 ships 'Include /etc/ssh/sshd_config.d/*.conf'; cloud
# providers land port overrides there, invisible to a file parse). Fallback:
# parse every ACTIVE Port line in the file when sshd -T is unavailable or
# fails (non-root, tests, sshd not installed).
_sshd_effective_ports() {
    local cfg=$1 out=""
    out="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')" || out=""
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
    [[ -f "$cfg" ]] || return 0
    awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' "$cfg"
    return 0
}

# N5: more than one effective Port means the firewall can only be coherent with
# one of them — a classic post-reboot lockout (the live session rides ufw's
# ESTABLISHED rule, which a reboot drops). Requires an explicit typed 'yes':
# does NOT honor --yes and refuses non-interactive (require_yes semantics, like
# the disk-wipe gate) because this is a lockout-risk decision.
_base_multiport_gate() {                          # <ports, one per line>
    local ports=$1 n
    n=$(printf '%s\n' "$ports" | grep -c .) || true
    (( n > 1 )) || return 0
    warn "sshd has ${n} effective Port directives: $(printf '%s' "$ports" | tr '\n' ' ')"
    warn "ufw can only be made coherent with ONE SSH port — the wrong one locks you out after reboot."
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would require a typed 'yes' to proceed with multiple sshd ports"
        return 0
    fi
    require_yes "Proceed anyway with multiple sshd Port directives?" \
        || fail "Aborted on multiple sshd Port directives — consolidate /etc/ssh/sshd_config (and sshd_config.d/) to a single Port, then re-run."
    return 0
}

# N5 (write side): leave EXACTLY ONE Port directive. The old ensure_line edit
# replaced only the FIRST match — including a commented '#Port 22' — so an
# image with '#Port 22' + a provider-appended 'Port 2222' kept TWO active
# directives after the edit (read/write incoherence, firewall opens one of
# them). Replace ALL commented/active Port lines with the single new directive
# at the FIRST one's position (append if none). Routed through _commit, so a
# content-identical rewrite is a no-op and the canonical single-Port image
# produces a byte-identical file.
_sshd_write_port() {                              # <cfg> <port>
    local cfg=$1 port=$2 tmp
    _ensure_parent "$cfg"
    tmp=$(_mktemp)
    if [[ -e "$cfg" ]]; then
        awk -v repl="Port ${port}" '
            /^[[:space:]]*#?[[:space:]]*Port[[:space:]]/ { if (!done) { print repl; done=1 }; next }
            { print }
            END { if (!done) print repl }
        ' "$cfg" >"$tmp"
    else
        printf 'Port %s\n' "$port" >"$tmp"
    fi
    _commit "$cfg" "$tmp" "sshd Port -> ${port} (single directive)"
}

# Success (0) if SSHD is listening on tcp <port>. If ss is unavailable we
# CANNOT verify — fail closed (return 1 = "not listening") so the caller rolls
# the SSH change back rather than trusting an unverifiable success and risking a
# remote lockout. ss ships in Ubuntu's base iproute2, so the proven path is
# unchanged; this only hardens the ss-absent edge. (X5)
# N14: when the process column is readable (-p; needs privilege), require the
# matching listener to actually BE sshd — any daemon parked on the port used to
# false-pass this verify-or-rollback gate. If no matching socket exposes
# process info (capability-restricted), fall back to the port-only match —
# never weaker than the previous check.
_ssh_listening_on() {
    local port=$1
    have ss || { warn "cannot verify SSH listener — 'ss' (iproute2) not found; treating as NOT listening (fail-closed)"; return 1; }
    ss -tlnpH 2>/dev/null | awk -v p=":${port}\$" '
        $4 ~ p { found=1; if ($0 ~ /users:\(\(/) { anyproc=1; if ($0 ~ /"sshd"/) issshd=1 } }
        END { if (!found) exit 1; if (anyproc) exit (issshd ? 0 : 1); exit 0 }'
}

# --- config resolution -------------------------------------------------------
_base_resolve_config() {
    if [[ -z "${SSH_PORT:-}" ]]; then
        ask "SSH port (changing from 22 is recommended)" "22"
        SSH_PORT="$REPLY"
    fi
    _valid_port "$SSH_PORT" || fail "Invalid SSH_PORT '$SSH_PORT' (must be 1-65535)"
    [[ "$SSH_PORT" == "22" ]] && warn "SSH_PORT is 22 (default) — a non-default port reduces noise/attack surface"
    # ssh_port is persisted to state ONLY after the change actually lands (in
    # base_firewall, from the live sshd config) — recording the *desired* port here
    # is what let a declined change firewall a port nothing listens on (S1).

    # The single early DoubleZero decision, alongside the SSH-port prompt. Records
    # dz_enabled to state; every later phase reads it (no re-prompt). Guarded so
    # base.sh sources/tests standalone even if doublezero.sh isn't loaded.
    if declare -F dz_should_enable >/dev/null 2>&1; then dz_should_enable || true; fi
}

# --- packages ----------------------------------------------------------------
base_packages() {
    step "Installing base packages (${#BASE_PACKAGES[@]} packages)"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    # apt upgrade fires only on the FIRST run (state-marker guarded), never on a
    # re-run/--only/--force against an already-deployed live node — pulling a
    # kernel on a synced validator would force an ill-timed reboot.
    if [[ "$BASE_APT_UPGRADE" == "true" ]]; then
        if state_has base_apt_upgraded; then
            info "apt upgrade skipped — already upgraded on a prior run (no surprise kernel bump on a live node)"
        else
            run apt-get upgrade -y
            state_set base_apt_upgraded "$(_ts)"
        fi
    fi
    run apt-get install -y "${BASE_PACKAGES[@]}"
    ok "Base packages installed"
    # DoubleZero packages + env (no staked key needed) — done here with the base
    # packages. Gated on the Phase 1 enable decision.
    if [[ "$(state_get dz_enabled false)" == "true" ]]; then
        declare -F dz_install_packages >/dev/null 2>&1 && dz_install_packages
        declare -F dz_env_override     >/dev/null 2>&1 && dz_env_override
    fi
}

# --- SSH port (verify-or-rollback) -------------------------------------------
base_ssh_port() {
    local port="$SSH_PORT" cfg="${SSHD_CONFIG:-/etc/ssh/sshd_config}" current
    step "SSH port -> ${port}"
    current=$(_sshd_configured_port "$cfg")

    if [[ "$current" == "$port" ]] && _ssh_listening_on "$port"; then
        ok "sshd already configured and listening on port $port"
        return 0
    fi

    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would set sshd Port=$port, switch socket->service, restart, verify"
        return 0
    fi

    # N5: surface MULTIPLE effective Port directives (provider image, or a box
    # damaged by the old first-match edit) before layering a change on top.
    _base_multiport_gate "$(_sshd_effective_ports "$cfg")"

    warn "Changing SSH port ${current:-22} -> ${port}. You must reconnect with:  ssh -p ${port} <user>@<host>"
    if ! confirm "Proceed with SSH port change to ${port}?" Y; then
        warn "SSH port change skipped by operator — sshd stays on ${current:-22}"
        # The change was NOT applied: fall back to the port sshd is actually on so
        # base_firewall opens the right port, never the declined one (S1).
        SSH_PORT="${current:-22}"
        return 0
    fi

    backup_file "$cfg"
    # Replace ALL commented/active Port lines with exactly ONE directive (N5).
    _sshd_write_port "$cfg" "$port"

    # Ubuntu 24.04 socket-activates sshd; switch to the service so sshd_config
    # Port takes effect (matches the guide).
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
        run systemctl disable --now ssh.socket
        run systemctl enable ssh
    fi

    if ! run systemctl restart ssh; then
        _base_ssh_rollback "$cfg" "$port" "ssh failed to restart"
    fi
    if _ssh_listening_on "$port"; then
        ok "sshd listening on port ${port}"
        warn "Reconnect on the new port now (keep this session open until you confirm):  ssh -p ${port} ..."
    else
        _base_ssh_rollback "$cfg" "$port" "sshd not listening on ${port} after restart"
    fi
}

_base_ssh_rollback() {
    local cfg=$1 port=$2 why=$3
    warn "SSH port change problem: ${why}."
    warn "Rolling back sshd config — DO NOT close your current session."
    restore_file "$cfg"
    run systemctl restart ssh 2>/dev/null || run systemctl restart ssh.socket 2>/dev/null || true
    # Reset to the restored (old) port so the firewall opens what sshd is back on,
    # if it is ever reached on this path (S1 defense-in-depth).
    SSH_PORT="$(_sshd_configured_port "$cfg")"; SSH_PORT="${SSH_PORT:-22}"
    fail "SSH port change to ${port} failed and was rolled back. Investigate sshd config/journal before retrying."
}

# --- firewall (core validator rules only) ------------------------------------
base_firewall() {
    local cfg="${SSHD_CONFIG:-/etc/ssh/sshd_config}" port prev ports p2
    step "Configuring ufw (core validator rules)"
    # Open the port(s) sshd will ACTUALLY listen on (sshd -T view, with a
    # file-parse fallback — N5) — NOT the desired SSH_PORT, which differs if the
    # operator declined the port change. Limiting only the new port would lock
    # the operator out after the reboot (the live session rides ufw's
    # ESTABLISHED rule, which a reboot drops). No readable effective port means
    # sshd is on the stock default 22. (S1)
    ports="$(_sshd_effective_ports "$cfg")"; ports="${ports:-22}"
    # N5: multiple effective ports -> explicit gate (this fires when the port
    # edit was skipped/declined on a multi-port image; on confirm, EVERY
    # effective port is limited so none of them is firewalled shut).
    _base_multiport_gate "$ports"
    port="$(printf '%s\n' "$ports" | head -1)"
    run ufw default deny incoming
    run ufw default allow outgoing
    # SSH FIRST and rate-limited, so enabling ufw can never lock the operator out.
    while IFS= read -r p2; do
        [[ -n "$p2" ]] || continue
        run ufw limit "${p2}/tcp" comment "SSH"
    done <<<"$ports"
    # Drop a stale SSH rule from a PRIOR port — added AFTER the new rule so there
    # is never a window without an SSH rule. state holds the last realized port;
    # deleting a non-existent rule is non-fatal; NEVER delete a rule for a port
    # sshd still effectively listens on. (I7, N5)
    prev="$(state_get ssh_port "")"
    if [[ -n "$prev" ]] && _valid_port "$prev" && ! grep -qx "$prev" <<<"$ports"; then
        run ufw delete limit "${prev}/tcp" >/dev/null 2>&1 || true
    fi
    # Gossip (TCP+UDP) and the dynamic port range (UDP: TPU/TVU/repair). Read the
    # SAME overridable vars validatorcfg uses so the firewall can't diverge from
    # the validator's own ports; ufw wants the range in colon form. (P12)
    local gossip="${GOSSIP_PORT:-8001}" dyn="${DYNAMIC_PORT_RANGE:-8900-9000}"
    run ufw allow "${gossip}/tcp" comment "gossip"
    run ufw allow "${gossip}/udp" comment "gossip"
    run ufw allow "${dyn//-/:}/udp" comment "solana-dynamic"
    # NOTE: public 8899/tcp (RPC) and 8900/tcp (pubsub) are deliberately NOT
    # opened — RPC is --private-rpc on 127.0.0.1. DoubleZero/relayer rules are
    # added by their own modules.
    # DoubleZero firewall (GRE/BGP/44880) BEFORE enabling, so the rules are in
    # place atomically. doublezero0-bound rules are accepted before the interface
    # exists (it appears at connect, post-swap). Gated on the Phase 1 decision.
    if [[ "$(state_get dz_enabled false)" == "true" ]] && declare -F dz_firewall >/dev/null 2>&1; then
        dz_firewall
    fi
    run ufw --force enable
    # Persist the realized SSH port (post-success) — re-runs and `deeploy export`
    # then reflect what sshd is actually on, never a desired-but-declined port (S1).
    state_set ssh_port "$port"
    ok "ufw enabled (SSH limited on ${port}, gossip ${gossip}, dynamic ${dyn//-/:}/udp; RPC kept private)"
}

# --- orchestrator ------------------------------------------------------------
base_run() {
    require_root
    _base_resolve_config
    base_packages
    base_ssh_port
    base_firewall
}
