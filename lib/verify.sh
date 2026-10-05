#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/verify.sh   (post-install verification; also `deeploy verify`)
# Read-only diagnostic ported from the operator's verification block. Checks
# that the tuning actually took: process limits, priority/OOM, CPU isolation
# (vs the recorded isolated set), PoH thread affinity (vs POH_CORE), the mlx5
# NIC's IRQs (off the isolated CPUs), governor/THP/KSM/NUMA, sysctl buffers,
# disk layout, catchup, the poh-pin timer, and whether the node runs on the
# staked identity.
#
# Never mutates anything. Probes are wrapped so tests can inject fixtures.
# Requires: common.sh sourced (constants.sh optional).
# ============================================================================

[[ -n "${_DEEPLOY_VERIFY_SOURCED:-}" ]] && return 0
_DEEPLOY_VERIFY_SOURCED=1

_VF_WARN=0; _VF_FAIL=0
vf_ok()   { ok "$@"; }
vf_warn() { _VF_WARN=$((_VF_WARN + 1)); warn "$@"; }
vf_fail() { _VF_FAIL=$((_VF_FAIL + 1)); printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; _log FAIL "$*"; }
# _vf_expect <label> <actual> <expected>  -> ok if equal, else warn.
_vf_expect() { if [[ "$2" == "$3" ]]; then vf_ok "$1 = $3"; else vf_warn "$1 = ${2:-?} (expected $3)"; fi; }

# --- mockable probes ---------------------------------------------------------
# Each probe ends with `|| true`: under set -e+pipefail a probe whose command
# legitimately returns non-zero (pgrep no match, systemctl is-active when
# inactive, cat of a /sys file absent on this kernel, catchup mid-sync, taskset
# on an empty tid) must NOT errexit the caller — every check tolerates empty
# output by design (`[[ -z ... ]]` / `_vf_expect`).
_vf_pid()          { pgrep -f '^agave-validator --identity' 2>/dev/null | head -1 || true; }
_vf_proc_limits()  { cat "/proc/$1/limits" 2>/dev/null || true; }
_vf_coredump_filter() { cat "/proc/$1/coredump_filter" 2>/dev/null || true; }
_vf_oom_score()    { cat "/proc/$1/oom_score_adj" 2>/dev/null || true; }
_vf_proc_nice()    { ps -o ni= -p "$1" 2>/dev/null | tr -d ' ' || true; }
_vf_poh_thread()   { ps -T -p "$1" -o spid,comm 2>/dev/null | awk '/solPohTickProd/{print $1; exit}' || true; }
_vf_taskset()      { taskset -cp "$1" 2>/dev/null | awk '{print $NF}' || true; }
_vf_isolated()     { cat /sys/devices/system/cpu/isolated 2>/dev/null || true; }
_vf_governors() {               # stdout: "cpuN <governor>" per cpufreq CPU; VF_CPU_SYSFS = tests' fake sysfs
    local f c
    for f in "${VF_CPU_SYSFS:-/sys/devices/system/cpu}"/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -r "$f" ]] || continue
        c=${f%/cpufreq/scaling_governor}
        printf '%s %s\n' "${c##*/}" "$(cat "$f" 2>/dev/null || true)"
    done
}
_vf_nic()          { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true; }
_vf_nic_bus()      { ethtool -i "$1" 2>/dev/null | awk -F': ' '/^bus-info:/{print $2; exit}' || true; }
_vf_mlx5_irqs() {               # <pci addr>; stdout: "<irq> <name> <effective CPUs>" per mlx5 IRQ; VF_PROC = tests' fake /proc
    local p=${VF_PROC:-/proc} irq name
    awk -v bus="$1" '{n = $NF; at = index(n, "@pci:")}
        at && substr(n, at + 5) == bus {sub(":", "", $1); print $1, n}' "$p/interrupts" 2>/dev/null |
        while read -r irq name; do
            printf '%s %s %s\n' "$irq" "$name" "$(cat "$p/irq/$irq/effective_affinity_list" 2>/dev/null || true)"
        done || true
}
_vf_thp()          { cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; }
_vf_ksm()          { cat /sys/kernel/mm/ksm/run 2>/dev/null || true; }
_vf_numa()         { cat /proc/sys/kernel/numa_balancing 2>/dev/null || true; }
_vf_sysctl()       { sysctl -n "$1" 2>/dev/null || true; }
_vf_catchup()      { "$SOLANA_BIN/solana" catchup --our-localhost 2>&1 | head -1 || true; }
_vf_timer_active() { systemctl is-active solana-poh-pin.timer 2>/dev/null || true; }
_vf_identity()     { deeploy_live_identity; }     # getIdentity, local RPC (common.sh)
_vf_sync_pubkey()  { deeploy_sync_pubkey; }

# --- checks ------------------------------------------------------------------
verify_process() {
    VF_PID=$(_vf_pid)
    if [[ -n "$VF_PID" ]]; then vf_ok "agave-validator running (pid $VF_PID)"
    else vf_fail "agave-validator is NOT running"; fi
}

verify_limits() {
    [[ -n "${VF_PID:-}" ]] || return 0
    local lim nofile core
    lim=$(_vf_proc_limits "$VF_PID")
    nofile=$(awk '/Max open files/{print $4}' <<<"$lim")
    _vf_expect "open files limit" "$nofile" "2000000"
    if grep -qE 'Max locked memory[[:space:]]+(unlimited|[0-9])' <<<"$lim"; then vf_ok "locked memory limit set"
    else vf_warn "locked memory limit not set"; fi
    # No core dumps: the validator's memory holds its identity key (R10-10).
    core=$(awk '/^Max core file size/{print $5 "/" $6}' <<<"$lim")
    _vf_expect "core dump limit (soft/hard)" "$core" "0/0"
    _vf_expect "coredump_filter" "$(_vf_coredump_filter "$VF_PID")" "00000010"
}

verify_priority() {
    [[ -n "${VF_PID:-}" ]] || return 0
    _vf_expect "nice"          "$(_vf_proc_nice "$VF_PID")" "-10"
    _vf_expect "oom_score_adj" "$(_vf_oom_score "$VF_PID")" "-1000"
}

verify_isolation() {
    local want actual; want=$(state_get isolated_set "")
    actual=$(_vf_isolated)
    [[ -z "$want" ]] && { info "no recorded isolated set to compare"; return 0; }
    if [[ "$actual" == "$want" ]]; then vf_ok "CPU isolation active: $actual"
    else vf_fail "isolated CPUs = '${actual:-<none>}' but expected '$want' (GRUB not applied / wrong reboot?)"; fi
}

verify_poh_affinity() {
    [[ -n "${VF_PID:-}" ]] || return 0
    local poh tid aff; poh=$(state_get poh_core "")
    tid=$(_vf_poh_thread "$VF_PID")
    [[ -n "$tid" ]] || { vf_warn "solPohTickProd thread not found yet (catchup may be ongoing)"; return 0; }
    aff=$(_vf_taskset "$tid")
    if [[ -n "$poh" && "$aff" == "$poh" ]]; then vf_ok "PoH thread pinned to core $poh"
    else vf_warn "PoH thread affinity = ${aff:-?} (expected $poh)"; fi
}

_vf_cpus() {                    # "1-2,10" -> " 1 2 10 "
    local part i out=" "
    for part in ${1//,/ }; do
        if [[ "$part" == *-* ]]; then for ((i = ${part%-*}; i <= ${part#*-}; i++)); do out+="$i "; done
        else out+="$part "; fi
    done
    printf '%s' "$out"
}

# Every mlx5 IRQ of the default-route NIC, not the queues a map names: comp34
# sat on the PoH core's SMT sibling, outside the old hardcoded map. An
# isolated CPU keeps none, an XDP core included. (R10-3, R10-3b)
verify_nic_irqs() {
    [[ "$(state_get nic_driver "")" == mlx5_core ]] || return 0
    local nic bus iso list irq name eff c bad="" total=0
    nic=$(_vf_nic)
    [[ -n "$nic" ]] || { vf_warn "mlx5 IRQs: no default-route NIC"; return 0; }
    bus=$(_vf_nic_bus "$nic")
    [[ -n "$bus" ]] || { vf_warn "mlx5 IRQs: no PCI address for $nic (ethtool -i)"; return 0; }
    iso=$(_vf_cpus "$(_vf_isolated)")
    list=$(_vf_mlx5_irqs "$bus")
    while read -r irq name eff; do
        [[ -n "$irq" ]] || continue
        total=$((total + 1))
        for c in $(_vf_cpus "$eff"); do
            if [[ "$iso" == *" $c "* ]]; then bad+="${bad:+ }${name%%@*}(irq $irq)->cpu$c"; break; fi
        done
    done <<<"$list"
    if (( total == 0 )); then vf_warn "mlx5 IRQs: none found for $nic (pci $bus)"
    elif [[ -z "$bad" ]]; then vf_ok "mlx5 IRQs of $nic: none of ${total} on an isolated CPU"
    else vf_warn "mlx5 IRQs of $nic on isolated CPUs: ${bad} (mlx5-irq-affinity.service should have moved them)"; fi
}

# Every cpufreq CPU, not cpu0 alone (R10-2): after a reboot the cpufrequtils
# boot script and performance-tweaks raced and left a mix, 32 of 48 CPUs on
# ondemand. cpu0 cannot show a mix, and performance there would hide one.
verify_governors() {
    local list perf total others
    list=$(_vf_governors)
    read -r perf total <<<"$(awk 'NF{t++; if ($2 == "performance") p++} END{print p+0, t+0}' <<<"$list")"
    if (( total == 0 )); then vf_warn "governor = ? (no cpufreq CPU found; expected performance)"; return 0; fi
    if (( perf == total )); then vf_ok "governor = performance on ${perf}/${total} CPUs"; return 0; fi
    others=$(awk 'NF && $2 != "performance"' <<<"$list" | sort -t u -k2,2n | awk '{printf "%s%s(%s)", s, $1, ($2 == "" ? "?" : $2); s = " "}')
    vf_warn "governor = performance on ${perf}/${total} CPUs (expected all); the others: ${others}"
}

verify_perf_tweaks() {
    local t; t=$(_vf_thp)
    verify_governors
    if [[ "$t" == *"[never]"* ]]; then vf_ok "THP = never"; else vf_warn "THP = ${t:-?} (expected [never])"; fi
    _vf_expect "KSM"            "$(_vf_ksm)"  "0"
    _vf_expect "numa_balancing" "$(_vf_numa)" "0"
}

verify_sysctl() {
    _vf_expect "net.core.rmem_max" "$(_vf_sysctl net.core.rmem_max)" "134217728"
    _vf_expect "fs.nr_open"        "$(_vf_sysctl fs.nr_open)"        "2000000"
}

verify_catchup() {
    local out; out=$(_vf_catchup)
    if grep -qE 'has caught up|^0 slot\(s\) behind' <<<"$out"; then vf_ok "catchup: $out"
    else vf_warn "not caught up: ${out:-<no response>}"; fi
}

verify_pohpin_timer() {
    if [[ "$(_vf_timer_active)" == "active" ]]; then vf_ok "solana-poh-pin.timer active"
    else vf_warn "solana-poh-pin.timer NOT active"; fi
}

# The staked identity is set at runtime (set-identity), so any restart of solana
# brings the node back on the sync identity, and it stops voting. Before the
# swap that is the expected state; after it, it is the thing to catch. Needs the
# staked pubkey: offbox records it at phase 5, file mode where it is derived.
verify_identity() {
    local staked live sync
    staked=$(state_get staked_pubkey "")
    [[ -n "$staked" ]] || { info "staked pubkey not recorded — identity check skipped"; return 0; }
    live=$(_vf_identity)
    [[ -n "$live" ]] || { vf_warn "identity unknown: getIdentity on the local RPC did not answer"; return 0; }
    if [[ "$live" == "$staked" ]]; then vf_ok "running on the staked identity ${staked}"; return 0; fi
    sync=$(_vf_sync_pubkey)
    if [[ -n "$sync" && "$live" == "$sync" ]]; then
        vf_warn "NOT voting as staked: the node runs on the sync identity ${sync} — expected before the swap; after a swap it means a restart reverted the identity"
    else
        vf_warn "identity ${live} is neither the staked ${staked} nor the sync identity ${sync:-?}"
    fi
}

# --- orchestrator ------------------------------------------------------------
verify_run() {
    step "Post-install verification"
    # Re-resolve WITHOUT $HOME: verify runs inside Phase 8 via the systemd resume
    # service, where $HOME is empty (the source-time default would be "/.local/..").
    SOLANA_BIN="$(deeploy_solana_bin)"
    _VF_WARN=0; _VF_FAIL=0
    verify_process
    verify_limits
    verify_priority
    verify_isolation
    verify_poh_affinity
    verify_nic_irqs
    verify_perf_tweaks
    verify_sysctl
    verify_catchup
    verify_identity
    verify_pohpin_timer
    echo ""
    info "Verification: ${_VF_WARN} warning(s), ${_VF_FAIL} failure(s)"
    if [[ "$_VF_FAIL" -gt 0 ]]; then vf_warn "Verification found ${_VF_FAIL} failure(s) — review above"; return 1; fi
    ok "Verification passed"
}
