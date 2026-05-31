#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/preflight.sh   (Phase 0: audit / gating)
# Read-only system audit. Never mutates the system, so it is identical under
# --dry-run. Hard-gates on anything that makes a sound deploy impossible;
# warns (does not block) on the soft stuff. Records findings to run-state for
# later phases (NIC driver, data-disk count, retransmit eligibility).
#
# Requires: common.sh and constants.sh already sourced.
#
# Testability: every external probe (curl/ping/ss/ethtool/ip/lsblk/findmnt/
# timedatectl/nproc/uname/systemd-detect-virt/lvs) is a real command call so
# tests can shadow it with a shell function; /proc and /etc/os-release paths
# are overridable via env (PROC_CPUINFO, PROC_MEMINFO, PROC_MDSTAT,
# OS_RELEASE_FILE) so tests can point at fixtures.
# ============================================================================

[[ -n "${_DEEPLOY_PREFLIGHT_SOURCED:-}" ]] && return 0
_DEEPLOY_PREFLIGHT_SOURCED=1

# Soft thresholds (warn below these). Tunable; not hard gates.
PF_MIN_CORES="${PF_MIN_CORES:-24}"
PF_MIN_RAM_GIB="${PF_MIN_RAM_GIB:-256}"
PF_MIN_MBPS="${PF_MIN_MBPS:-200}"

# Opt-in active bandwidth probe (hits a public CDN). Off by default so the
# audit makes no surprise external calls; enabled with --net-test.
: "${NET_TEST:=0}"

# Result counters (globals so individual checks are unit-testable in isolation).
_PF_HARD=0
_PF_WARN=0

pf_ok()   { ok "$@"; }
pf_warn() { _PF_WARN=$((_PF_WARN + 1)); warn "$@"; }
pf_bad()  { _PF_HARD=$((_PF_HARD + 1)); printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; _log FAIL "$*"; }

# Strip a partition to its base disk: nvme0n1p2 -> nvme0n1 ; sda2 -> sda.
_pf_base_disk() {
    local s=${1##*/}
    if   [[ "$s" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^([a-z]+)[0-9]+$ ]];             then printf '%s' "${BASH_REMATCH[1]}"
    else printf '%s' "$s"; fi
}

# --- platform: arch, OS, virtualization --------------------------------------
_pf_check_platform() {
    local arch osr id ver virt
    arch=$(uname -m 2>/dev/null || true)
    if [[ "$arch" == "x86_64" ]]; then pf_ok "Architecture: x86_64"
    else pf_bad "Architecture '${arch:-unknown}' unsupported — DeePloy builds for x86_64"; fi

    osr="${OS_RELEASE_FILE:-/etc/os-release}"
    # Parse (not source) os-release: avoids executing its contents and keeps
    # the linter happy about the dynamic path.
    id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' "$osr" 2>/dev/null)
    ver=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2; exit}' "$osr" 2>/dev/null)
    if [[ "$id" != "ubuntu" ]]; then pf_bad "OS is '${id:-unknown}' — DeePloy targets Ubuntu 24.04"
    elif [[ "$ver" != "24.04" ]]; then pf_warn "Ubuntu $ver detected (tested on 24.04)"
    else pf_ok "Ubuntu 24.04"; fi

    if have systemd-detect-virt; then
        virt=$(systemd-detect-virt 2>/dev/null || true)
        info "Virtualization: ${virt:-none}"
    fi
}

# --- CPU: cores, AES-NI ------------------------------------------------------
_pf_check_cpu() {
    local cpuinfo="${PROC_CPUINFO:-/proc/cpuinfo}" logical model
    if have nproc; then logical=$(nproc 2>/dev/null); else logical=$(grep -c '^processor' "$cpuinfo" 2>/dev/null || echo 0); fi
    model=$(grep -m1 '^model name' "$cpuinfo" 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')
    info "CPU: ${model:-unknown} (${logical:-0} logical cores)"
    if grep -qm1 '\baes\b' "$cpuinfo" 2>/dev/null; then pf_ok "AES-NI present"
    else pf_warn "AES-NI not detected — Solana signature verification will be slow"; fi
    if [[ "${logical:-0}" -lt "$PF_MIN_CORES" ]]; then
        pf_warn "${logical:-0} logical cores (<${PF_MIN_CORES}) — mainnet realistically wants 32+"
    else pf_ok "${logical} logical cores"; fi
}

# --- memory + swap -----------------------------------------------------------
_pf_check_memory() {
    local meminfo="${PROC_MEMINFO:-/proc/meminfo}" kb swkb gib swgib
    kb=$(awk '/^MemTotal:/{print $2; exit}' "$meminfo" 2>/dev/null)
    swkb=$(awk '/^SwapTotal:/{print $2; exit}' "$meminfo" 2>/dev/null)
    gib=$(( ${kb:-0} / 1048576 ))
    swgib=$(( ${swkb:-0} / 1048576 ))
    if [[ "$gib" -lt "$PF_MIN_RAM_GIB" ]]; then
        pf_warn "RAM ${gib} GiB (<${PF_MIN_RAM_GIB}) — mainnet validators typically need 256-512 GiB"
    else pf_ok "RAM ${gib} GiB"; fi
    [[ "$swgib" -gt 0 ]] && info "Swap ${swgib} GiB present (Phase 3 disables swap)"
    return 0
}

# --- storage: enumerate disks, count data disks, RAID/LVM hints --------------
_pf_check_storage() {
    if ! have lsblk; then pf_warn "lsblk absent — storage audit skipped"; return 0; fi
    local rootsrc rootdisk count=0 name size type rota model
    if have findmnt; then rootsrc=$(findmnt -no SOURCE / 2>/dev/null); fi
    rootdisk=$(_pf_base_disk "${rootsrc:-}")
    info "Root filesystem: ${rootsrc:-?}  (system disk: ${rootdisk:-?})"
    while read -r name size type rota model; do
        [[ "$type" == "disk" ]] || continue
        if [[ "$name" == "$rootdisk" ]]; then
            info "  /dev/$name  $size  [system]  ${model:-}"
        else
            count=$((count + 1))
            info "  /dev/$name  $size  rota=$rota  [data candidate]  ${model:-}"
        fi
    done < <(lsblk -dn -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null)
    state_set data_disk_count "$count"
    if [[ "$count" -lt 2 ]]; then
        pf_warn "$count data disk(s) besides system — Phase 3 recommends 2 (accounts/ledger on separate disks)"
    else pf_ok "$count data disks available besides system"; fi

    local mdstat="${PROC_MDSTAT:-/proc/mdstat}"
    if [[ -f "$mdstat" ]] && grep -qE '^md[0-9]' "$mdstat" 2>/dev/null; then
        pf_warn "Software RAID (md) detected — Phase 3 will use a single-volume root layout"
    fi
    if have lvs && lvs >/dev/null 2>&1; then info "LVM present (Phase 3 will note single-volume layout)"; fi
    return 0
}

# --- NIC + XDP retransmit eligibility ----------------------------------------
_pf_check_nic() {
    if ! have ip; then pf_warn "iproute2 (ip) absent — NIC audit skipped"; return 0; fi
    local nic driver d
    nic=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$nic" ]] && nic=$(ip -br link 2>/dev/null | awk '$1!="lo" && $2=="UP"{print $1; exit}')
    if [[ -z "$nic" ]]; then pf_warn "No active uplink NIC detected"; return 0; fi
    driver=""
    if have ethtool; then driver=$(ethtool -i "$nic" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}'); fi
    state_set nic_driver "$driver"
    if [[ -z "$driver" ]]; then
        state_set retransmit_supported 0; state_set retransmit_zero_copy 0
        pf_warn "NIC $nic: driver unknown (ethtool absent) — XDP retransmit gated OFF"
        return 0
    fi
    local supported=0 zc=0
    for d in "${RETRANSMIT_XDP_DRIVERS[@]}"; do [[ "$driver" == "$d" ]] && supported=1; done
    for d in "${RETRANSMIT_ZC_DRIVERS[@]}";  do [[ "$driver" == "$d" ]] && zc=1; done
    state_set retransmit_supported "$supported"
    state_set retransmit_zero_copy "$zc"
    if   [[ "$supported" == "1" && "$zc" == "1" ]]; then
        pf_ok "NIC $nic driver=$driver — XDP retransmit + zero-copy (will add mlx5-irq-affinity.service)"
    elif [[ "$supported" == "1" ]]; then
        pf_ok "NIC $nic driver=$driver — XDP retransmit, NO zero-copy (will add nic-tuning.service + ZC preflight)"
    else
        pf_warn "NIC $nic driver=$driver — XDP retransmit not supported yet; you can deploy with it disabled"
    fi
}

# --- time sync ---------------------------------------------------------------
_pf_check_time() {
    local synced
    if have timedatectl; then
        synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [[ "$synced" == "yes" ]]; then pf_ok "Clock NTP-synchronized"
        else pf_warn "Clock not NTP-synchronized — validators need accurate time"; fi
        return 0
    fi
    if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null \
        || systemctl is-active --quiet ntp 2>/dev/null || systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        pf_ok "Time-sync daemon active"
    else pf_warn "No time synchronization detected"; fi
}

# --- cluster reachability + genesis guard ------------------------------------
_pf_check_cluster() {
    if ! have curl; then pf_warn "curl absent — cluster/genesis check skipped"; return 0; fi
    local rpc="${DEFAULT_PUBLIC_RPC}" resp hash
    resp=$(curl -s -m 10 "$rpc" -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash"}' 2>/dev/null || true)
    hash=$(printf '%s' "$resp" | grep -oE '"result":"[A-Za-z0-9]+"' | head -1 | cut -d'"' -f4)
    if [[ -z "$hash" ]]; then
        pf_warn "Cluster RPC unreachable ($rpc) — verify internet connectivity"
    elif [[ "$hash" == "$MAINNET_GENESIS_HASH" ]]; then
        pf_ok "Cluster reachable; mainnet-beta genesis confirmed"
    else
        pf_bad "Genesis mismatch: RPC returned $hash, expected mainnet $MAINNET_GENESIS_HASH"
    fi
}

# --- closest Jito region (BAM + block-engine ping scoring via region.sh) -----
_pf_check_region() {
    if declare -F region_recommend >/dev/null 2>&1; then
        region_recommend || true
    else
        info "Region scoring unavailable (region.sh not loaded)"
    fi
}

# --- uplink bandwidth (opt-in active probe to a public CDN) ------------------
_pf_check_bandwidth() {
    if [[ "${NET_TEST:-0}" != "1" ]]; then
        info "Bandwidth probe skipped (enable with --net-test)"
        return 0
    fi
    if ! have curl; then info "Bandwidth probe skipped (curl absent)"; return 0; fi
    local bytes=26214400 url speed mbps
    url="https://speed.cloudflare.com/__down?bytes=${bytes}"
    info "Bandwidth probe -> ${url}"   # announce the endpoint before hitting it
    speed=$(curl -s -m 30 -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || true)
    if [[ -z "$speed" || "$speed" == "0" || "$speed" == 0.* ]]; then
        pf_warn "Bandwidth probe failed/blocked (best-effort) — verify uplink manually"
        return 0
    fi
    mbps=$(awk -v s="$speed" 'BEGIN{printf "%.0f", s*8/1000000}')
    if [[ "${mbps:-0}" -lt "$PF_MIN_MBPS" ]]; then
        pf_warn "Downlink ~${mbps} Mbps (<${PF_MIN_MBPS}) — mainnet wants 1 Gbps+ symmetric"
    else pf_ok "Downlink ~${mbps} Mbps (best-effort probe)"; fi
}

# --- port availability -------------------------------------------------------
_pf_check_ports() {
    if ! have ss; then info "Port check skipped (ss absent)"; return 0; fi
    local p hits conflict=0
    for p in "${SSH_PORT:-22}" 8001 8899 8900; do
        hits=$(ss -tulnH 2>/dev/null | awk -v port=":$p\$" '$5 ~ port {print $5; exit}')
        if [[ -n "$hits" ]]; then conflict=1; pf_warn "Port $p already in use ($hits)"; fi
    done
    [[ "$conflict" == "0" ]] && pf_ok "Required ports free (SSH/${SSH_PORT:-22}, 8001, 8899, 8900)"
    return 0
}

# --- existing DeePloy progress ----------------------------------------------
_pf_check_existing() {
    local cp p done_list=""
    cp=$(state_get current-phase "")
    if [[ -n "$cp" ]]; then
        pf_warn "A previous run stopped mid-phase ($cp) — 'deeploy.sh install --resume' continues it"
        return 0
    fi
    for p in 0 1 2 3 4 5 6 7 8; do is_phase_done "$p" && done_list="$done_list $p"; done
    [[ -n "$done_list" ]] && info "Existing progress (phases done):$done_list — re-runs are idempotent; --resume continues"
    return 0
}

# --- orchestrator ------------------------------------------------------------
preflight_run() {
    require_root
    _PF_HARD=0; _PF_WARN=0
    _pf_check_platform
    _pf_check_cpu
    _pf_check_memory
    _pf_check_storage
    _pf_check_nic
    _pf_check_time
    _pf_check_cluster
    _pf_check_region
    _pf_check_ports
    _pf_check_bandwidth
    _pf_check_existing
    echo ""
    info "Preflight: ${_PF_WARN} warning(s), ${_PF_HARD} blocking issue(s)"
    if [[ "$_PF_HARD" -gt 0 ]]; then
        fail "Preflight found ${_PF_HARD} blocking issue(s) above — resolve and re-run"
    fi
    ok "Preflight passed"
}
