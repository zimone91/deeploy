#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/base.sh   (Phase 1: base system)
# Packages, SSH-port change (with verify-or-rollback so a bad change can never
# lock the operator out), and the core validator firewall.
#
# Firewall scope: this module owns ONLY the core validator rules. DoubleZero
# (GRE proto 47 + BGP 179) lives in doublezero.sh; relayer/shred ports live in
# relayer.sh — each feature owns its own firewall rules.
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

# Success (0) if something is listening on tcp <port>. If ss is unavailable we
# cannot verify — return success so we never roll back a change blindly.
_ssh_listening_on() {
    local port=$1
    have ss || return 0
    ss -tlnH 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {found=1} END{exit !found}'
}

# --- config resolution -------------------------------------------------------
_base_resolve_config() {
    if [[ -z "${SSH_PORT:-}" ]]; then
        ask "SSH port (changing from 22 is recommended)" "22"
        SSH_PORT="$REPLY"
    fi
    _valid_port "$SSH_PORT" || fail "Invalid SSH_PORT '$SSH_PORT' (must be 1-65535)"
    [[ "$SSH_PORT" == "22" ]] && warn "SSH_PORT is 22 (default) — a non-default port reduces noise/attack surface"
    state_set ssh_port "$SSH_PORT"
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

    warn "Changing SSH port ${current:-22} -> ${port}. You must reconnect with:  ssh -p ${port} <user>@<host>"
    if ! confirm "Proceed with SSH port change to ${port}?" Y; then
        warn "SSH port change skipped by operator"
        return 0
    fi

    backup_file "$cfg"
    # Replace any commented/active Port line in place (else append).
    ensure_line "$cfg" "Port ${port}" "^[[:space:]]*#?[[:space:]]*Port[[:space:]]"

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
    fail "SSH port change to ${port} failed and was rolled back. Investigate sshd config/journal before retrying."
}

# --- firewall (core validator rules only) ------------------------------------
base_firewall() {
    local port="$SSH_PORT"
    step "Configuring ufw (core validator rules)"
    run ufw default deny incoming
    run ufw default allow outgoing
    # SSH FIRST and rate-limited, so enabling ufw can never lock the operator out.
    run ufw limit "${port}/tcp" comment "SSH"
    # Gossip (TCP+UDP) and the dynamic port range (UDP: TPU/TVU/repair).
    run ufw allow 8001/tcp comment "gossip"
    run ufw allow 8001/udp comment "gossip"
    run ufw allow 8900:9000/udp comment "solana-dynamic"
    # NOTE: public 8899/tcp (RPC) and 8900/tcp (pubsub) are deliberately NOT
    # opened — RPC is --private-rpc on 127.0.0.1. DoubleZero/relayer rules are
    # added by their own modules.
    run ufw --force enable
    ok "ufw enabled (SSH limited on ${port}, gossip 8001, dynamic 8900:9000/udp; RPC kept private)"
}

# --- orchestrator ------------------------------------------------------------
base_run() {
    require_root
    _base_resolve_config
    base_packages
    base_ssh_port
    base_firewall
}
