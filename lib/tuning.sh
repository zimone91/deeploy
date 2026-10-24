#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/tuning.sh   (Phase 2: kernel / CPU tuning)
# The highest-value automation: compute CPU core-isolation dynamically from the
# live topology (replacing the memo's 8 hand-built GRUB variants), write GRUB,
# performance-tweaks.service, sysctl, and NOFILE limits, then flag the reboot.
#
# XDP_CORES_COUNT is the single source of truth: it drives isolcpus/nohz_full/
# rcu_nocbs/irqaffinity here, and the XDP cores are recorded to state for
# validatorcfg (--xdp-cpu-cores) — no drift. There is no PoH core to set: see
# _isolation_compute.
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

# --- the core computation ----------------------------------------------------
# _isolation_compute <total> <xdp_count>  -> sets _ISO_SET, _ISO_IRQ, _ISO_XDP
#   isolated = the XDP cores: the lowest physical-core primaries from CPU 1 up,
#   each with its SMT siblings.  _ISO_SET = compressed isolated;  _ISO_IRQ =
#   compressed (all CPUs - isolated);  _ISO_XDP = compressed XDP primaries.
#   No XDP cores means nothing is isolated: all three are empty.
#
#   There is no PoH core. Under Alpenglow the pinned client (jito-solana
#   013a4306 = v4.3.2-jito) logs "Post Alpenglow migration, not starting
#   PohService" and returns (poh/src/poh_service.rs 121-129), so the CPU pin
#   after it (155-165) is never reached. What is left of --poh-pinned-cpu-core
#   is the check that --xdp-cpu-cores does not include the PoH core
#   (validator/src/commands/run/execute.rs 1515-1532). Without the flag that
#   core is CPU 0 on Linux (DEFAULT_PINNED_CPU_CORE = Some(0), poh_service.rs
#   43), so CPU 0 is never an XDP core: the loop starts at CPU 1, and CPU 0's
#   own SMT sibling is no physical-core primary.
_isolation_compute() {
    local total=$1 xdp=${2:-0} c primary x count=0
    local -a isolated=() xdp_primaries=()
    _ISO_SET=""; _ISO_IRQ=""; _ISO_XDP=""
    (( xdp > 0 )) || return 0
    for ((c=1; c<total; c++)); do
        primary=$(_cpu_primary "$c")
        [[ "$c" == "$primary" ]] || continue                     # only physical-core primaries
        xdp_primaries+=("$c")                                     # the retransmit cpu-cores
        while read -r x; do isolated+=("$x"); done < <(_expand_list "$(_cpu_siblings "$c")")
        count=$((count + 1)); (( count >= xdp )) && break
    done
    (( ${#isolated[@]} > 0 )) || return 0                         # a one-CPU box has no core to reserve
    local sorted; sorted=$(printf '%s\n' "${isolated[@]}" | sort -nu)
    _ISO_SET=$(printf '%s\n' "$sorted" | _compress_ranges)
    local i
    _ISO_IRQ=$(for ((i=0; i<total; i++)); do grep -qxF "$i" <<<"$sorted" || echo "$i"; done | _compress_ranges)
    _ISO_XDP=$(printf '%s\n' "${xdp_primaries[@]}" | sort -nu | _compress_ranges)
}

# The kernel params DeePloy appends: the fixed perf flags, and the XDP-core
# isolation when there is one (_ISO_SET empty = no isolcpus, nohz_full,
# rcu_nocbs or irqaffinity at all).
_isolation_grub_params() {
    local p='amd_pstate=passive nvme_core.default_ps_max_latency_us=0'
    if [[ -n "$_ISO_SET" ]]; then
        p+=" isolcpus=domain,managed_irq,${_ISO_SET} nohz_full=${_ISO_SET} rcu_nocbs=${_ISO_SET} irqaffinity=${_ISO_IRQ}"
    fi
    printf '%s' "$p"
}

# --- read-back: what grub-mkconfig ACTUALLY baked in -------------------------
# Writing /etc/default/grub is not the same as the kernel getting the parameters.
# grub-mkconfig sources /etc/default/grub.d/*.cfg afterwards, and a drop-in that
# assigns GRUB_CMDLINE_LINUX_DEFAULT replaces the line DeePloy just wrote. The
# run then reboots and the validator comes up with no isolation, which is
# indistinguishable from isolation that did not help. The mechanism and the image
# it was measured on are recorded on deeploy_grub_clobbering_dropins().
#
# So the source of truth is the GENERATED file, not the input we wrote.
#
# This returns a path and never calls fail(), because callers read it through
# $( ) — a subshell, where an exit would be swallowed and the caller would
# continue with an empty string.
#
# The candidate list is overridable for the same reason GRUB_FILE is: a fixture
# must be able to say "there is no grub.cfg" and be believed. Without that, a
# test for the not-found branch reads the RUNNER's own /boot/grub/grub.cfg and
# passes for the wrong reason on Linux while looking right on macOS.
GRUB_CFG_CANDIDATES=()                            # empty = the real locations below
_grub_generated_cfg() {                           # -> prints the path, or returns 1
    local c
    if (( ${#GRUB_CFG_CANDIDATES[@]} )); then
        for c in "${GRUB_CFG_CANDIDATES[@]}"; do
            [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
        done
        return 1
    fi
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Fail-closed on every branch, INCLUDING "no grub.cfg anywhere". The path depends
# on whether the box booted BIOS or EFI, so not finding one means the question is
# unanswered — not that it does not apply. An unanswered question here is a reboot
# onto an unverified kernel cmdline.
# Name the drop-in that is on THIS box, found now, rather than one this repo
# remembered from some image. If none is found the message says so, because
# blaming grub.d for a cause that is not there sends the operator to the wrong
# file — the cmdline can also be lost to a manual edit or a provider's own image.
_grub_clobber_hint() {
    local dir="${GRUB_D_DIR:-/etc/default/grub.d}" f hits=()
    while IFS= read -r f; do [[ -n "$f" ]] && hits+=("$f"); done < <(deeploy_grub_clobbering_dropins)
    if (( ${#hits[@]} )); then
        printf 'These drop-ins under %s assign GRUB_CMDLINE_LINUX_DEFAULT outright and grub-mkconfig sources them after /etc/default/grub, which is the likely cause: %s.' \
            "$dir" "${hits[*]}"
    else
        printf 'No drop-in under %s assigns GRUB_CMDLINE_LINUX_DEFAULT, so the cause is elsewhere — check for a manual edit of the generated file or a provider image that regenerates it.' "$dir"
    fi
}

_grub_assert_applied() {                          # <isolcpus-set> <nohz-set>; both empty = nothing isolated
    local want_iso=${1:-} want_nohz=${2:-} cfg
    if is_dry_run; then
        if [[ -n "$want_iso" ]]; then
            info "${C_DIM}[dry-run]${C_NC} would read the generated grub.cfg back and verify isolcpus=${want_iso}"
        else
            info "${C_DIM}[dry-run]${C_NC} would read the generated grub.cfg back and verify amd_pstate=passive and nvme_core.default_ps_max_latency_us=0 (no isolation)"
        fi
        return 0                                  # nothing was written, so there is nothing to read
    fi
    cfg=$(_grub_generated_cfg) || fail "Refusing: update-grub ran but no generated grub.cfg could be found (looked in /boot/grub, /boot/grub2 and the ESP). The path depends on BIOS vs EFI, so this is an unanswered question, not an inapplicable check — and the next step is a reboot onto whatever the bootloader actually has."
    if [[ -z "$want_iso" ]]; then
        # No XDP cores, so no isolation to read back; the managed perf parameters
        # are what update-grub must still have baked in.
        if ! { grep -q 'amd_pstate=passive' "$cfg" && grep -q 'nvme_core.default_ps_max_latency_us=0' "$cfg"; }; then
            fail "Refusing: ${cfg} does not carry amd_pstate=passive and nvme_core.default_ps_max_latency_us=0 after update-grub. $(_grub_clobber_hint) Not rebooting on a cmdline without the parameters DeePloy wrote."
        fi
        ok "Verified in ${cfg}: amd_pstate and nvme_core survived grub-mkconfig (no isolation: no XDP cores)"
        return 0
    fi
    grep -q "isolcpus=domain,managed_irq,${want_iso}" "$cfg" \
        || fail "Refusing: ${cfg} does not carry isolcpus=domain,managed_irq,${want_iso} after update-grub. $(_grub_clobber_hint) Not rebooting on a cmdline that lacks the isolation."
    grep -q "nohz_full=${want_nohz}" "$cfg" \
        || fail "Refusing: ${cfg} carries isolcpus but not nohz_full=${want_nohz} after update-grub. A partially applied cmdline is not a working one."
    ok "Verified in ${cfg}: isolcpus and nohz_full survived grub-mkconfig"
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
tuning_resolve_config() {
    TUNE_TOTAL=$(_cpu_total)
    if [[ -z "${XDP_CORES_COUNT:-}" ]]; then
        if [[ "$(state_get retransmit_supported 0)" == "1" ]]; then
            ask "Cores to reserve for XDP retransmit (prod default 2 -> cores 1-2)" "2"
            XDP_CORES_COUNT="$REPLY"
        else
            XDP_CORES_COUNT=0
        fi
    fi
    [[ "$XDP_CORES_COUNT" =~ ^[0-9]+$ ]] || fail "XDP_CORES_COUNT must be a number"
    state_set xdp_cores_count "$XDP_CORES_COUNT"
}

tuning_grub() {
    local grub="${GRUB_FILE:-/etc/default/grub}" cur stripped params new been_through_reboot=0
    _isolation_compute "$TUNE_TOTAL" "$XDP_CORES_COUNT"
    params=$(_isolation_grub_params)
    cur=$(_grub_current_cmdline "$grub")
    stripped=$(_grub_strip_managed "$cur")   # an older install's isolcpus/nohz_full/rcu_nocbs/irqaffinity go here
    new="${stripped:+$stripped }$params"
    step "CPU isolation (XDP cores=$XDP_CORES_COUNT, total CPUs=$TUNE_TOTAL)"
    if [[ -n "$_ISO_SET" ]]; then
        info "isolcpus/nohz_full/rcu_nocbs: $_ISO_SET (the XDP cores and their SMT siblings)"
        info "irqaffinity:                  $_ISO_IRQ"
    else
        info "no XDP cores are reserved, so nothing is isolated: no isolcpus, nohz_full, rcu_nocbs or irqaffinity"
    fi
    info "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\""
    state_has reboot_done && been_through_reboot=1
    backup_file "$grub"
    _grub_write_cmdline "$grub" "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\""   # exactly ONE line (N13)
    run update-grub
    _grub_assert_applied "$_ISO_SET" "$_ISO_SET"  # before any state is armed: a
                                                  # refusal here must leave no reboot pending
    state_set isolated_set "$_ISO_SET"            # empty when nothing is isolated; phase 8 then skips its check
    state_set irqaffinity  "$_ISO_IRQ"
    state_set xdp_cores    "$_ISO_XDP"
    state_set reboot_required 1
    # Re-arming a reboot INVALIDATES any prior completion latch: a sanctioned
    # re-tune (new XDP cores) must force a fresh reboot, not let the boundary proceed
    # to Phase 8 on a stale reboot_done against the OLD, still-live isolation (I1).
    state_clear reboot_done
    state_clear reboot_pending
    ok "GRUB updated — reboot required to apply the kernel parameters"
    (( been_through_reboot )) && info "This box has been through the reboot gate: the new GRUB parameters take effect at its next planned reboot (a staked node: move it to the standby first)."
    return 0
}

# --- performance tweaks (governor/THP/KSM/NUMA) ------------------------------
# cpufrequtils (a base package) sets every CPU's governor at boot from
# /etc/default/cpufrequtils — ondemand when the file is absent — and nothing
# ordered it against this unit: after a reboot 32 of 48 CPUs stayed on ondemand.
# So the file names performance too, and this unit runs after that boot script.
# The file may be the operator's (ENABLE, MAX_SPEED, MIN_SPEED), and the boot
# script sources it, so the LAST GOVERNOR= wins: leave EXACTLY ONE GOVERNOR=
# line, at the first one's position (append if none), and keep every other
# line. Routed through _commit, so a re-run is a no-op. (R10-2)
_tuning_write_cpufreq_governor() {                # <file>
    local f=$1 tmp
    _ensure_parent "$f"
    tmp=$(_mktemp)
    if [[ -e "$f" ]]; then
        awk -v repl='GOVERNOR="performance"' '
            /^[[:space:]]*GOVERNOR=/ { if (!done) { print repl; done=1 }; next }
            { print }
            END { if (!done) print repl }
        ' "$f" >"$tmp"
    else
        printf '%s\n' '# Written by DeePloy: the cpufrequtils boot script sets this governor on every CPU.' \
            'GOVERNOR="performance"' >"$tmp"
    fi
    _commit "$f" "$tmp" "cpufrequtils GOVERNOR=performance (single line)"
}

tuning_perf() {
    step "performance-tweaks.service"
    _tuning_write_cpufreq_governor "${CPUFREQ_DEFAULT_FILE:-/etc/default/cpufrequtils}"
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
# After=cpufrequtils.service (R10-2): the cpufrequtils boot script sets the
# governor too; running after it keeps performance the value that stays.
After=cpufrequtils.service

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

# --- huge pages for the XDP UMEM (R10-5) -------------------------------------
# Each XDP queue maps (rx + tx) x 2 frames of one 4 KiB page and asks for 2 MiB
# huge pages first (jito xdp/src/tx_loop.rs, umem.rs). With none reserved it
# falls back to regular pages and WARNs, once per queue per start: 2 WARN per
# start on the rc9 box. One XDP queue per XDP core; reserve twice what they
# take, from the default-route NIC's ring sizes now. Rings changed later need
# a recount. The pool is global: one NUMA node is the only layout measured.
_tuning_nic_rings() {                             # stdout: "<rx> <tx>" now, or nothing
    local nic
    nic=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    [[ -n "$nic" ]] || return 0
    # ethtool prints the maximums, then the current settings: the last RX:/TX: win.
    ethtool -g "$nic" 2>/dev/null | awk '$1 == "RX:" {rx = $2} $1 == "TX:" {tx = $2}
        END {if (rx ~ /^[0-9]+$/ && tx ~ /^[0-9]+$/) print rx, tx}' || true
}
_tuning_xdp_hugepages() {                         # <queues> <rx> <tx> -> 2 x the 2 MiB pages they map
    echo $(( 2 * $1 * ((($2 + $3) * 2 * 4096 + 2097151) / 2097152) ))
}

# --- sysctl ------------------------------------------------------------------
tuning_sysctl() {
    local f="${SYSCTL_FILE:-/etc/sysctl.d/21-agave-validator.conf}" xdp rx tx hp=""
    step "sysctl 21-agave-validator"
    xdp=$(state_get xdp_cores "")
    if [[ "$(state_get retransmit_supported 0)" == "1" && -n "$xdp" ]]; then  # XDP on: validatorcfg's test
        read -r rx tx <<<"$(_tuning_nic_rings)"
        # jito's own default when it cannot read the rings (xdp/src/device.rs)
        [[ -n "${rx:-}" ]] || { rx=1024 tx=1024; warn "NIC ring sizes unreadable (ethtool -g) — counting XDP huge pages for 1024/1024, jito's default"; }
        hp=$(_tuning_xdp_hugepages "$(_expand_list "$xdp" | wc -l | tr -d ' ')" "$rx" "$tx")
        info "XDP UMEM: cores ${xdp}, rings ${rx}/${tx} -> vm.nr_hugepages=${hp}"
        state_set xdp_hugepages "$hp"
    else
        state_clear xdp_hugepages
    fi
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
'"${hp:+
# Huge pages for the XDP UMEM: twice what the XDP queues map (R10-5)
vm.nr_hugepages=${hp}
}"
    # NOTE: fs.xfs.* tuning is intentionally NOT here. /proc/sys/fs/xfs/ only
    # exists once the xfs module is loaded (i.e. after Phase 3 makes the XFS
    # filesystems), so a sysctl applying it now would fail on a fresh box. The
    # XFS sync-interval is written + applied in Phase 3 (disk.sh) after mkfs.xfs.
    write_file "${SYSCTL_SERVICE_FILE:-/etc/systemd/system/solana-sysctl.service}" \
'[Unit]
Description=Apply Solana sysctl tuning
After=network.target local-fs.target
# Before=solana.service, as in performance-tweaks: solana starts after this
# re-apply, not beside it. Ordering only, so solana starts even if it fails.
Before=solana.service

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
    warn "The GRUB parameters (CPU isolation, where XDP cores are reserved) and DefaultLimitNOFILE take effect after the reboot gate."
}
