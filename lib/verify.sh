#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/verify.sh   (post-install verification; also `deeploy verify`)
# Read-only diagnostic ported from the operator's verification block. Checks
# that the tuning actually took: process limits, priority/OOM, CPU isolation
# (vs the recorded isolated set), PoH thread affinity (vs POH_CORE), the mlx5
# NIC's IRQs (off the isolated CPUs), governor/THP/KSM/NUMA, sysctl buffers,
# the XDP UMEM's huge pages, disk layout, catchup, the BAM connection, the
# poh-pin timer, and whether the node runs on the staked identity.
#
# Never mutates anything. Probes are wrapped so tests can inject fixtures.
# Requires: common.sh and constants.sh sourced.
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
_vf_hugepages()    { awk '$1 == "HugePages_Total:" {print $2; exit}' "${VF_MEMINFO:-/proc/meminfo}" 2>/dev/null || true; }
# "huge page alloc failed" lines since the last "Starting validator with:"
# (jito validator/src/commands/run/execute.rs) in the validator's log. jito
# logs them right after the start line, and solana.log rotates daily: with no
# start line in it (rotated since the start, or no log at all, where awk fails
# before END) this prints nothing, and the fallback is not checked.
_vf_hugepage_fails() {
    awk '/Starting validator with:/ {s = 1; n = 0} /huge page alloc failed/ {n++} END {if (s) print n + 0}' \
        "$(state_get solana_home /root/solana)/solana.log" 2>/dev/null || true
}
_vf_catchup()      { deeploy_catchup_status; }    # two bounded getSlot reads (common.sh)
# BAM connection attempts in solana.log (R10-8). Each attempt of jito's BAM
# manager ends in exactly one of three lines (core/src/bam_manager.rs @
# c21f9074): "Failed to connect to BAM with url" (187), "BAM connection not
# healthy after waiting for …" (199-203) or "BAM connection established"
# (210); "BAM connection unhealthy" (222) is a loss after that. The duration in
# the not-healthy line is a constant (MAX_DURATION_BETWEEN_NODE_HEARTBEATS),
# not the time waited, and is not read. Why an attempt failed is the server's
# status, logged by core/src/bam_connection.rs 199. solana.log grows ~3 MB/min
# and rotates daily, so grep -aF picks the lines and awk reads only those. The
# log's first and last timestamped lines, within 1000 lines of either end,
# bound the window (a multi-line entry, such as the start line's argument
# list, has no timestamp on the lines after its first).
_vf_log_first() {
    head -n 1000 "$(state_get solana_home /root/solana)/solana.log" 2>/dev/null \
        | sed -n 's/^\[\([0-9][-0-9T:.]*Z\) .*/\1/p' | head -n 1 || true
}
_vf_log_last() {
    tail -n 1000 "$(state_get solana_home /root/solana)/solana.log" 2>/dev/null \
        | sed -n 's/^\[\([0-9][-0-9T:.]*Z\) .*/\1/p' | tail -n 1 || true
}
_vf_bam_lines() {
    grep -aF -e 'Starting validator with:' -e 'Failed to connect to BAM with url' \
        -e 'BAM connection not healthy after waiting for' -e 'BAM connection established' \
        -e 'BAM connection unhealthy' -e 'Challenge expired (elapsed since creation: ' \
        -e 'Validator is not on the leader schedule' \
        "$(state_get solana_home /root/solana)/solana.log" 2>/dev/null || true
}
_vf_timer_active() { systemctl is-active solana-poh-pin.timer 2>/dev/null || true; }
_vf_identity()     { deeploy_live_identity; }     # getIdentity, local RPC (common.sh)
_vf_sync_pubkey()  { deeploy_sync_pubkey; }
# The vote account as the public RPC parses it (getAccountInfo, jsonParsed), and
# the rent-exempt minimum for its size. Each prints nothing when nothing answers.
_vf_vote_account() {           # <vote pubkey, already checked to be 32 bytes of base58>
    curl -sS -m 5 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"$1\",{\"encoding\":\"jsonParsed\"}]}" \
        "$DEFAULT_PUBLIC_RPC" 2>/dev/null || true
}
_vf_rent_min() {               # <bytes>
    curl -sS -m 5 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getMinimumBalanceForRentExemption\",\"params\":[$1]}" \
        "$DEFAULT_PUBLIC_RPC" 2>/dev/null | sed -nE 's/.*"result"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' || true
}

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

# The XDP UMEM's huge pages (R10-5): the pool phase 2 reserved, and no fall
# back to regular pages since the validator last started. XDP off: no check.
verify_hugepages() {
    local want have fails
    want=$(state_get xdp_hugepages "")
    [[ -n "$want" ]] || return 0
    have=$(_vf_hugepages)
    if [[ "$have" =~ ^[0-9]+$ ]] && (( have >= want )); then vf_ok "HugePages_Total = ${have} (>= ${want} for the XDP UMEM)"
    else vf_warn "HugePages_Total = ${have:-?} (expected >= ${want} for the XDP UMEM; vm.nr_hugepages)"; fi
    fails=$(_vf_hugepage_fails)
    if [[ -z "$fails" ]]; then info "no 'Starting validator with:' in solana.log (rotated since the start, or no log) — the XDP huge page fallback is not checked"
    elif (( fails == 0 )); then vf_ok "XDP UMEM on huge pages: no 'huge page alloc failed' since the last start"
    else vf_warn "XDP UMEM fell back to regular pages: ${fails} 'huge page alloc failed' since the last start (solana.log)"; fi
}

verify_catchup() {
    local out; out=$(_vf_catchup)
    if [[ "$out" == "caught up "* ]]; then vf_ok "catchup: $out"
    else vf_warn "not caught up: $out"; fi
}

# The BAM lines of solana.log (on stdin) in the window that ends at the log's
# last timestamp ($2) and starts at the latest of: 10 min before it, the last
# "Starting validator with:", the log's first timestamp ($1). Lines after the
# end, written while grep read the growing log, are not in the window. The
# last connection event decides: established is ok, a loss, a failed connect
# or a not-healthy attempt is a warn, none is info. Prints one line, its first
# word ok / warn / info. Dates are counted in awk (days from civil and back):
# BSD awk has no mktime, and mawk need not have one.
_vf_bam_window() {
    awk -v first="$1" -v last="$2" '
    function secs(t,   y, m, d, e, yoe) {
        y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
        y -= (m <= 2); e = int(y / 400); yoe = y - e * 400
        return (e * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) \
            + int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1 - 719468) * 86400 \
            + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
    }
    function stamp(s,   z, e, doe, yoe, doy, mp, m) {
        z = int(s / 86400) + 719468; s %= 86400; e = int(z / 146097); doe = z - e * 146097
        yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
        doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
        m = mp < 10 ? mp + 3 : mp - 9
        return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", yoe + e * 400 + (m <= 2), m,
            doy - int((153 * mp + 2) / 5) + 1, int(s / 3600), int(s % 3600 / 60), s % 60)
    }
    function zero() { est = nh = cf = lost = ce = ls = n = out = 0; mx = ev = ""; split("", seen) }
    BEGIN {
        zero(); to = secs(last); from = to - 600; why = "last 10 min"
        # no first timestamp ("") counts as long before any window
        if (secs(first) > from) { from = secs(first); why = "since solana.log begins" }
    }
    { t = substr($1, 2) }
    secs(t) > to { next }
    /Starting validator with:/ {
        if (secs(t) >= from) { from = secs(t); why = "since the validator start" }
        zero()
    }
    secs(t) < from { next }
    /Failed to connect to BAM with url/ { cf++; ev = "connect failed"; et = t }
    /BAM connection not healthy after waiting for/ { nh++; ev = "not healthy"; et = t }
    /BAM connection established/ { est++; ev = "established"; et = t }
    /BAM connection unhealthy/ { lost++; ev = "lost"; et = t }
    /Validator is not on the leader schedule/ { ls++ }
    /Challenge expired \(elapsed since creation: / {
        ce++
        v = $0; sub(/.*elapsed since creation: /, "", v); sub(/,.*/, "", v)
        a = $0; sub(/.*max allowed: /, "", a); sub(/\).*/, "", a)
        if (!(a in seen)) { seen[a] = 1; mx = mx (mx == "" ? "" : ", ") a }
        if (v ~ /^[0-9.]+ms$/) { n++; key[n] = v + 0; txt[n] = v }
        else if (v ~ /^[0-9.]+s$/) { n++; key[n] = v * 1000; txt[n] = v }
        else out++
    }
    END {
        if (from > to) { print "info BAM: the timestamps of solana.log run backwards (" stamp(from) " after " stamp(to) ") — the connection is not checked"; exit }
        span = stamp(from) " to " stamp(to) " (" why ")"
        if (ev == "") { print "info BAM: no connection event, " span "; a steady connection logs none"; exit }
        for (i = 2; i <= n; i++) {
            k = key[i]; x = txt[i]
            for (j = i - 1; j > 0 && key[j] > k; j--) { key[j + 1] = key[j]; txt[j + 1] = txt[j] }
            key[j + 1] = k; txt[j + 1] = x
        }
        r = n ? "elapsed p50 " txt[int((n + 1) / 2)] : ""
        if (out) r = r (r == "" ? "" : ", ") out " not in p50"
        if (mx != "") r = r (r == "" ? "" : ", ") "max allowed " mx
        print (ev == "established" ? "ok BAM: connected since " stamp(secs(et)) : \
            "warn BAM: not connected, last event " stamp(secs(et)) " (" ev ")") ", " span ": " \
            est " established, " nh " not healthy, " cf " connect failed, " lost " lost after established; " \
            "Challenge expired " ce (r == "" ? "" : " (" r ")") ", not on the leader schedule " ls
    }'
}

# BAM (R10-8): only where validator.sh gets --bam-url, that is unless the MEV
# mode is relayer (validatorcfg.sh). The window's last connection event
# decides: established is ok, a loss or a failed attempt is a WARN, and no
# event is info: a steady connection logs none.
verify_bam() {
    local last out
    [[ "$(state_get mev_mode bam)" != relayer ]] || return 0
    last=$(_vf_log_last)
    if [[ -z "$last" ]]; then info "BAM: no timestamped line in solana.log — the connection is not checked"; return 0; fi
    out=$(_vf_bam_lines | _vf_bam_window "$(_vf_log_first)" "$last")
    case "$out" in
        "ok "*)   vf_ok   "${out#ok }" ;;
        "warn "*) vf_warn "${out#warn }" ;;
        *)        info    "${out#info }" ;;
    esac
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

# Alpenglow needs a BLS key in the vote account (blsPubkeyCompressed), and burns
# a validator admission ticket from it every epoch: the account must hold its
# rent-exempt minimum plus VAT_LAMPORTS_PER_EPOCH (constants.sh). Alpenglow is
# active on mainnet-beta since epoch 1064 and DeePloy runs on mainnet-beta only
# (MAINNET_GENESIS_HASH), so there is no branch for a cluster before it. Read from
# the public RPC and advisory, like the on-chain identity check in phase 5 (R10-6):
# a problem warns, no answer is info.
verify_vote_account() {
    local vote acct lamports space rent need
    vote=$(state_get vote_account_pubkey "")
    [[ -n "$vote" ]] || { info "vote account pubkey not recorded — BLS key and VAT balance not checked"; return 0; }
    [[ "$(b58_len "$vote")" == 32 ]] || { vf_warn "vote account pubkey '${vote}' is not 32 bytes of base58 — not checked"; return 0; }
    acct=$(_vf_vote_account "$vote")
    if grep -qE '"value"[[:space:]]*:[[:space:]]*null' <<<"$acct"; then
        vf_warn "vote account ${vote} does not exist on ${DEFAULT_PUBLIC_RPC} (getAccountInfo answered null) — BLS key and VAT balance not checked"; return 0
    fi
    lamports=$(printf '%s\n' "$acct" | sed -nE 's/.*"lamports"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
    space=$(printf '%s\n' "$acct" | sed -nE 's/.*"space"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
    if [[ -z "$lamports" || -z "$space" ]]; then
        info "vote account ${vote} not read from ${DEFAULT_PUBLIC_RPC} — BLS key and VAT balance not checked"; return 0
    fi
    if grep -qE '"blsPubkeyCompressed"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$acct"; then
        vf_ok "vote account carries a BLS key (blsPubkeyCompressed)"
    else
        vf_warn "vote account ${vote} has no BLS key (blsPubkeyCompressed): Alpenglow needs one in the vote account"
    fi
    rent=$(_vf_rent_min "$space")
    [[ -n "$rent" ]] || { info "rent-exempt minimum for ${space} bytes not read from ${DEFAULT_PUBLIC_RPC} — VAT balance not checked"; return 0; }
    need=$(( rent + VAT_LAMPORTS_PER_EPOCH ))
    if (( lamports >= need )); then
        vf_ok "vote account holds ${lamports} lamports: rent ${rent} + $(( (lamports - rent) / VAT_LAMPORTS_PER_EPOCH )) epoch(s) of VAT (${VAT_LAMPORTS_PER_EPOCH} each)"
    else
        vf_warn "vote account holds ${lamports} lamports, below rent ${rent} + one epoch of VAT ${VAT_LAMPORTS_PER_EPOCH} = ${need}. Alpenglow is active on mainnet-beta, so the VAT minimum applies"
    fi
}

# --- orchestrator ------------------------------------------------------------
verify_run() {
    step "Post-install verification"
    # Re-resolve WITHOUT $HOME: verify runs inside Phase 8 via the systemd resume
    # service, where $HOME is empty (the source-time default would be "/.local/..").
    # shellcheck disable=SC2034  # read by deeploy_sync_pubkey (common.sh) in verify_identity
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
    verify_hugepages
    verify_catchup
    verify_bam
    verify_identity
    verify_vote_account
    verify_pohpin_timer
    echo ""
    info "Verification: ${_VF_WARN} warning(s), ${_VF_FAIL} failure(s)"
    if [[ "$_VF_FAIL" -gt 0 ]]; then vf_warn "Verification found ${_VF_FAIL} failure(s) — review above"; return 1; fi
    ok "Verification passed"
}
