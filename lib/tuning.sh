#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/tuning.sh   (Phase 2: kernel / CPU tuning)
# The highest-value automation: compute CPU core-isolation dynamically from the
# live topology (replacing the memo's 8 hand-built GRUB variants), write GRUB,
# performance-tweaks.service, sysctl, and NOFILE limits, then flag the reboot.
#
# POH_CORE is the single source of truth: it drives isolcpus/nohz_full/
# rcu_nocbs/irqaffinity here, and is recorded to state for validatorcfg
# (--experimental-poh-pinned-cpu-core) and set_poh_affinity.sh — no drift.
#
# Requires: common.sh sourced. Topology is read via _cpu_total/_cpu_siblings,
# which tests override to inject a synthetic CPU layout; file paths are
# env-overridable (GRUB_FILE, SYSCTL_FILE, ...) so writers hit fixtures.
# ============================================================================

[[ -n "${_DEEPLOY_TUNING_SOURCED:-}" ]] && return 0
_DEEPLOY_TUNING_SOURCED=1

# GRUB cmdline keys DeePloy manages (stripped before re-adding, for idempotent
# re-runs that never duplicate or leave stale isolation params).
TUNING_MANAGED_GRUB_KEYS=(amd_pstate nvme_core.default_ps_max_latency_us isolcpus nohz_full rcu_nocbs irqaffinity)

# --- topology (overridable in tests) -----------------------------------------
_cpu_total()    { if have nproc; then nproc; else grep -c '^processor' "${PROC_CPUINFO:-/proc/cpuinfo}"; fi; }
_cpu_siblings() {                       # thread_siblings_list for logical cpu $1
    local f="${CPU_SYSFS_ROOT:-/sys/devices/system/cpu}/cpu${1}/topology/thread_siblings_list"
    if [[ -r "$f" ]]; then cat "$f"; else echo "$1"; fi
}
_cpu_primary()  { _expand_list "$(_cpu_siblings "$1")" | sort -n | head -1; }   # lowest sibling = physical-core primary

# --- list helpers ------------------------------------------------------------
# "1-2,10,25-26" -> one integer per line (ranges expanded).
_expand_list() {
    local IFS=',' part a b i
    for part in $1; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            for ((i=a; i<=b; i++)); do echo "$i"; done
        else
            echo "$part"
        fi
    done
}

# stdin: sorted unique integers, one per line -> "a-b,c,d-e" (no trailing newline).
_compress_ranges() {
    awk '
        function flush(){ if(start==prev) printf "%s%s", sep, start; else printf "%s%s-%s", sep, start, prev; sep="," }
        NR==1 { start=prev=$1; next }
        $1==prev+1 { prev=$1; next }
        { flush(); start=prev=$1 }
        END { if (NR>0) flush() }
    '
}

_array_has() { local n=$1; shift; local e; for e in "$@"; do [[ "$e" == "$n" ]] && return 0; done; return 1; }

# --- the core computation ----------------------------------------------------
# _isolation_compute <total> <poh_core> <xdp_count>  -> sets _ISO_SET, _ISO_IRQ
#   isolated = PoH core's sibling set  (+ for each extra XDP core: the lowest
#   physical-core primaries, excluding core 0 and the PoH core, with siblings)
#   _ISO_SET = compressed isolated;  _ISO_IRQ = compressed (all CPUs - isolated)
_isolation_compute() {
    local total=$1 poh=$2 xdp=${3:-0} c primary x count=0
    local -a isolated=() xdp_primaries=()
    while read -r x; do isolated+=("$x"); done < <(_expand_list "$(_cpu_siblings "$poh")")
    if (( xdp > 0 )); then
        for ((c=1; c<total; c++)); do
            primary=$(_cpu_primary "$c")
            [[ "$c" == "$primary" ]] || continue                 # only physical-core primaries
            _array_has "$c" "${isolated[@]}" && continue          # skip the PoH core itself
            xdp_primaries+=("$c")                                 # the retransmit cpu-cores
            while read -r x; do isolated+=("$x"); done < <(_expand_list "$(_cpu_siblings "$c")")
            count=$((count + 1)); (( count >= xdp )) && break
        done
    fi
    local sorted; sorted=$(printf '%s\n' "${isolated[@]}" | sort -nu)
    _ISO_SET=$(printf '%s\n' "$sorted" | _compress_ranges)
    local i
    _ISO_IRQ=$(for ((i=0; i<total; i++)); do grep -qxF "$i" <<<"$sorted" || echo "$i"; done | _compress_ranges)
    if (( ${#xdp_primaries[@]} > 0 )); then
        _ISO_XDP=$(printf '%s\n' "${xdp_primaries[@]}" | sort -nu | _compress_ranges)
    else
        _ISO_XDP=""
    fi
}

# The kernel params DeePloy appends (PoH/XDP isolation + the fixed perf flags).
_isolation_grub_params() {
    printf 'amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,%s nohz_full=%s rcu_nocbs=%s irqaffinity=%s' \
        "$_ISO_SET" "$_ISO_SET" "$_ISO_SET" "$_ISO_IRQ"
}

# --- GRUB rewrite (idempotent, preserves provider base params) ---------------
_grub_current_cmdline() {
    local grub=$1
    [[ -f "$grub" ]] || return 0
    # Both quote styles (N13): provider images ship single-quoted values too;
    # the old double-quote-only parse returned EMPTY for those, silently
    # DROPPING the provider's base params (console=ttyS0, ...) on the rewrite.
    sed -n -e 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' \
           -e "s/^GRUB_CMDLINE_LINUX_DEFAULT='\(.*\)'\$/\1/p" "$grub" | tail -1
}

# N13 (write side): leave EXACTLY ONE GRUB_CMDLINE_LINUX_DEFAULT line. The old
# ensure_line edit replaced only the FIRST match while the read takes the LAST
# — on a file with duplicate lines the two sides acted on different lines, and
# the stale duplicate is what GRUB would actually honor. Replace ALL of them
# with the single new line at the FIRST one's position (append if none).
# Routed through _commit: a content-identical rewrite is a no-op, so the
# canonical single-line file stays byte-identical.
_grub_write_cmdline() {                           # <grub-file> <full-new-line>
    local grub=$1 newline=$2 tmp
    _ensure_parent "$grub"
    tmp=$(_mktemp)
    if [[ -e "$grub" ]]; then
        awk -v repl="$newline" '
            /^GRUB_CMDLINE_LINUX_DEFAULT=/ { if (!done) { print repl; done=1 }; next }
            { print }
            END { if (!done) print repl }
        ' "$grub" >"$tmp"
    else
        printf '%s\n' "$newline" >"$tmp"
    fi
    _commit "$grub" "$tmp" "GRUB_CMDLINE_LINUX_DEFAULT (single line)"
}
# Drop DeePloy-managed tokens, keep everything else (vendor console=, mpt3sas, …).
_grub_strip_managed() {
    local token key out="" managed
    for token in $1; do
        key="${token%%=*}"
        managed=0
        for m in "${TUNING_MANAGED_GRUB_KEYS[@]}"; do [[ "$key" == "$m" ]] && managed=1; done
        [[ "$managed" == "1" ]] || out="${out:+$out }$token"
    done
    printf '%s' "$out"
}

# --- config resolution -------------------------------------------------------
_valid_cpu() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 < $2 )); }

# Default PoH core: the production default is core 10 (when it's a valid
# physical-core primary on this box). Falls back to the 3rd physical-core
# primary (reserve cores 0,1 for OS/IRQ), then lower, on smaller boxes.
TUNING_DEFAULT_POH_CORE="${TUNING_DEFAULT_POH_CORE:-10}"
_default_poh_core() {
    local total=$1 c primary; local -a prim=()
    if (( total > TUNING_DEFAULT_POH_CORE )) && [[ "$(_cpu_primary "$TUNING_DEFAULT_POH_CORE")" == "$TUNING_DEFAULT_POH_CORE" ]]; then
        echo "$TUNING_DEFAULT_POH_CORE"; return
    fi
    for ((c=0; c<total; c++)); do
        primary=$(_cpu_primary "$c")
        [[ "$c" == "$primary" ]] && prim+=("$c")
    done
    if   (( ${#prim[@]} >= 3 )); then echo "${prim[2]}"
    elif (( ${#prim[@]} >= 2 )); then echo "${prim[1]}"
    else echo 1; fi
}

tuning_resolve_config() {
    TUNE_TOTAL=$(_cpu_total)
    if [[ -z "${POH_CORE:-}" ]]; then
        ask "PoH pinned core (isolated; the single source of truth for pinning)" "$(_default_poh_core "$TUNE_TOTAL")"
        POH_CORE="$REPLY"
    fi
    _valid_cpu "$POH_CORE" "$TUNE_TOTAL" || fail "POH_CORE '$POH_CORE' is not a valid CPU (0..$((TUNE_TOTAL - 1)))"
    [[ "$POH_CORE" == "0" ]] && warn "POH_CORE=0 is the housekeeping core — strongly discouraged"
    if [[ -z "${XDP_CORES_COUNT:-}" ]]; then
        if [[ "$(state_get retransmit_supported 0)" == "1" ]]; then
            ask "Cores to reserve for XDP retransmit (prod default 2 -> cores 1-2)" "2"
            XDP_CORES_COUNT="$REPLY"
        else
            XDP_CORES_COUNT=0
        fi
    fi
    [[ "$XDP_CORES_COUNT" =~ ^[0-9]+$ ]] || fail "XDP_CORES_COUNT must be a number"
    state_set poh_core "$POH_CORE"
    state_set xdp_cores_count "$XDP_CORES_COUNT"
}

tuning_grub() {
    local grub="${GRUB_FILE:-/etc/default/grub}" cur stripped params new
    _isolation_compute "$TUNE_TOTAL" "$POH_CORE" "$XDP_CORES_COUNT"
    params=$(_isolation_grub_params)
    cur=$(_grub_current_cmdline "$grub")
    stripped=$(_grub_strip_managed "$cur")
    new="${stripped:+$stripped }$params"
    step "CPU isolation (POH_CORE=$POH_CORE, XDP cores=$XDP_CORES_COUNT, total CPUs=$TUNE_TOTAL)"
    info "isolcpus/nohz_full/rcu_nocbs: $_ISO_SET"
    info "irqaffinity:                  $_ISO_IRQ"
    info "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\""
    backup_file "$grub"
    _grub_write_cmdline "$grub" "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\""   # exactly ONE line (N13)
    run update-grub
    state_set isolated_set "$_ISO_SET"
    state_set irqaffinity  "$_ISO_IRQ"
    state_set xdp_cores    "$_ISO_XDP"
    state_set reboot_required 1
    # Re-arming a reboot INVALIDATES any prior completion latch: a sanctioned
    # re-tune (new POH/XDP) must force a fresh reboot, not let the boundary proceed
    # to Phase 8 on a stale reboot_done against the OLD, still-live isolation (I1).
    state_clear reboot_done
    state_clear reboot_pending
    ok "GRUB updated — reboot required to apply CPU isolation"
}

# --- performance tweaks (governor/THP/KSM/NUMA) ------------------------------
tuning_perf() {
    step "performance-tweaks.service"
    write_file "${PERF_SCRIPT_FILE:-/usr/local/bin/performance-tweaks.sh}" \
'#!/bin/bash
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo 0 > /sys/kernel/mm/ksm/run
echo 0 > /proc/sys/kernel/numa_balancing
' 0755
    write_file "${PERF_SERVICE_FILE:-/etc/systemd/system/performance-tweaks.service}" \
'[Unit]
Description=Apply performance tuning parameters
# Before=solana.service (H3): governor/THP/KSM/numa must be applied before the
# validator starts. Replaces After=multi-user.target, which both let solana
# start first AND would form an ordering cycle combined with Before= (solana
# is itself pulled in by multi-user.target). Matches the shape of the NIC units.
Before=solana.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/performance-tweaks.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'
    run systemctl daemon-reload
    run systemctl enable --now performance-tweaks.service
    ok "performance-tweaks enabled (governor=performance, THP=never, KSM=0, numa_balancing=0)"
}

# --- sysctl ------------------------------------------------------------------
tuning_sysctl() {
    local f="${SYSCTL_FILE:-/etc/sysctl.d/21-agave-validator.conf}"
    step "sysctl 21-agave-validator"
    write_file "$f" \
'# TCP Buffer Sizes (10k min, 87.38k default, 12M max)
net.ipv4.tcp_rmem=10240 87380 12582912
net.ipv4.tcp_wmem=10240 87380 12582912

# UDP buffer sizes (critical for Solana gossip/QUIC)
net.core.rmem_default=134217728
net.core.rmem_max=134217728
net.core.wmem_default=134217728
net.core.wmem_max=134217728

# TCP Optimization
net.ipv4.tcp_congestion_control=westwood
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1

# Kernel Optimization
kernel.timer_migration=0
kernel.hung_task_timeout_secs=30
kernel.pid_max=4194304
kernel.nmi_watchdog=0

# Virtual Memory Tuning
vm.swappiness=0
vm.max_map_count=2000000
vm.stat_interval=10
vm.dirty_ratio=40
vm.dirty_background_ratio=10
vm.min_free_kbytes=3000000
vm.dirty_expire_centisecs=36000
vm.dirty_writeback_centisecs=3000
vm.dirtytime_expire_seconds=43200

# File descriptors
fs.nr_open=2000000
'
    # NOTE: fs.xfs.* tuning is intentionally NOT here. /proc/sys/fs/xfs/ only
    # exists once the xfs module is loaded (i.e. after Phase 3 makes the XFS
    # filesystems), so a sysctl applying it now would fail on a fresh box. The
    # XFS sync-interval is written + applied in Phase 3 (disk.sh) after mkfs.xfs.
    write_file "${SYSCTL_SERVICE_FILE:-/etc/systemd/system/solana-sysctl.service}" \
'[Unit]
Description=Apply Solana sysctl tuning
After=network.target local-fs.target

[Service]
Type=oneshot
# -e: ignore keys this kernel does not know (net.ipv4.tcp_low_latency was
# removed in 4.14; the westwood module may be absent) — a plain -p made this
# unit FAIL on every boot on such kernels. (N10)
ExecStart=/usr/sbin/sysctl -e -p '"$f"'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
'
    apply_sysctl_file "$f"          # tolerant: a not-yet-present key warns, never aborts the run
    run systemctl daemon-reload
    run systemctl enable --now solana-sysctl.service
    ok "sysctl applied"
}

# --- NOFILE limits -----------------------------------------------------------
tuning_limits() {
    step "NOFILE limits"
    write_file "${LIMITS_FILE:-/etc/security/limits.d/90-solana-nofiles.conf}" \
'# Increase process file descriptor count limit
* - nofile 2000000
'
    # DefaultLimitNOFILE under [Manager]; replace-or-append, never duplicate.
    ensure_kv "${SYSTEM_CONF:-/etc/systemd/system.conf}" "DefaultLimitNOFILE" "2000000"
    run systemctl daemon-reexec
    ok "NOFILE limit set to 2000000 (limits.d + systemd DefaultLimitNOFILE)"
}

# --- orchestrator ------------------------------------------------------------
tuning_run() {
    require_root
    tuning_resolve_config
    tuning_grub
    tuning_perf
    tuning_sysctl
    tuning_limits
    warn "CPU isolation (GRUB) and DefaultLimitNOFILE take effect after the reboot gate."
}
