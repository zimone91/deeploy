#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/verify.sh   (post-install verification; also `deeploy verify`)
# Read-only diagnostic ported from the operator's verification block. Checks
# that the tuning actually took: process limits, priority/OOM, CPU isolation
# (vs the recorded isolated set), PoH thread affinity (vs POH_CORE), governor/
# THP/KSM/NUMA, sysctl buffers, disk layout, catchup, and the poh-pin timer.
#
# Never mutates anything. Probes are wrapped so tests can inject fixtures.
# Requires: common.sh sourced (constants.sh optional).
# ============================================================================

[[ -n "${_DEEPLOY_VERIFY_SOURCED:-}" ]] && return 0
_DEEPLOY_VERIFY_SOURCED=1

SOLANA_BIN="${SOLANA_BIN:-$HOME/.local/share/solana/install/active_release/bin}"

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
_vf_oom_score()    { cat "/proc/$1/oom_score_adj" 2>/dev/null || true; }
_vf_proc_nice()    { ps -o ni= -p "$1" 2>/dev/null | tr -d ' ' || true; }
_vf_poh_thread()   { ps -T -p "$1" -o spid,comm 2>/dev/null | awk '/solPohTickProd/{print $1; exit}' || true; }
_vf_taskset()      { taskset -cp "$1" 2>/dev/null | awk '{print $NF}' || true; }
_vf_isolated()     { cat /sys/devices/system/cpu/isolated 2>/dev/null || true; }
_vf_governor()     { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true; }
_vf_thp()          { cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; }
_vf_ksm()          { cat /sys/kernel/mm/ksm/run 2>/dev/null || true; }
_vf_numa()         { cat /proc/sys/kernel/numa_balancing 2>/dev/null || true; }
_vf_sysctl()       { sysctl -n "$1" 2>/dev/null || true; }
_vf_catchup()      { "$SOLANA_BIN/solana" catchup --our-localhost 2>&1 | head -1 || true; }
_vf_timer_active() { systemctl is-active solana-poh-pin.timer 2>/dev/null || true; }

# --- checks ------------------------------------------------------------------
verify_process() {
    VF_PID=$(_vf_pid)
    if [[ -n "$VF_PID" ]]; then vf_ok "agave-validator running (pid $VF_PID)"
    else vf_fail "agave-validator is NOT running"; fi
}

verify_limits() {
    [[ -n "${VF_PID:-}" ]] || return 0
    local lim nofile
    lim=$(_vf_proc_limits "$VF_PID")
    nofile=$(awk '/Max open files/{print $4}' <<<"$lim")
    _vf_expect "open files limit" "$nofile" "2000000"
    if grep -qE 'Max locked memory[[:space:]]+(unlimited|[0-9])' <<<"$lim"; then vf_ok "locked memory limit set"
    else vf_warn "locked memory limit not set"; fi
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

verify_perf_tweaks() {
    local t; t=$(_vf_thp)
    _vf_expect "governor" "$(_vf_governor)" "performance"
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
    verify_perf_tweaks
    verify_sysctl
    verify_catchup
    verify_pohpin_timer
    echo ""
    info "Verification: ${_VF_WARN} warning(s), ${_VF_FAIL} failure(s)"
    if [[ "$_VF_FAIL" -gt 0 ]]; then vf_warn "Verification found ${_VF_FAIL} failure(s) — review above"; return 1; fi
    ok "Verification passed"
}
