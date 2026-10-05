#!/usr/bin/env bash
# Self-contained tests for lib/verify.sh — the _vf_* probe wrappers are
# overridden to inject a "good" or "bad" system, asserting ok vs warn/fail.
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/verify.sh
source "$ROOT/lib/verify.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
reset() { _VF_WARN=0; _VF_FAIL=0; }

DRY_RUN=0 common_init
state_set isolated_set "1-2,10,25-26,34"
state_set poh_core 10

# "Good" system
_vf_pid()          { echo 12345; }
_vf_proc_limits()  { printf 'Max core file size        0           0           bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
_vf_coredump_filter() { echo 00000010; }
_vf_proc_nice()    { echo "-10"; }
_vf_oom_score()    { echo "-1000"; }
_vf_poh_thread()   { echo 999; }
_vf_taskset()      { echo "10"; }
_vf_isolated()     { echo "1-2,10,25-26,34"; }
# Fake cpufreq sysfs (R10-2): mkcpus <gov of cpu0> <gov of the others> <count>
mkcpus() { local i; rm -rf "$WORK/cpu"
    for ((i = 0; i < $3; i++)); do mkdir -p "$WORK/cpu/cpu$i/cpufreq"
        if (( i == 0 )); then echo "$1"; else echo "$2"; fi >"$WORK/cpu/cpu$i/cpufreq/scaling_governor"; done; }
mkcpus performance performance 4; export VF_CPU_SYSFS="$WORK/cpu"
_vf_thp()          { echo "always madvise [never]"; }
_vf_ksm()          { echo 0; }
_vf_numa()         { echo 0; }
_vf_sysctl()       { case "$1" in net.core.rmem_max) echo 134217728;; fs.nr_open) echo 2000000;; esac; }
_vf_catchup()      { echo "caught up (us:100 them:100)"; }
_vf_timer_active() { echo active; }

echo "== good system: every check clean =="
reset; verify_process      >/dev/null 2>&1; check "process running"  "$_VF_FAIL/$_VF_WARN" "0/0"
reset; verify_limits       >/dev/null 2>&1; check "limits ok"        "$_VF_WARN" "0"
reset; verify_priority     >/dev/null 2>&1; check "priority ok"      "$_VF_WARN" "0"
reset; verify_isolation    >/dev/null 2>&1; check "isolation ok"     "$_VF_FAIL" "0"
reset; verify_poh_affinity >/dev/null 2>&1; check "poh affinity ok"  "$_VF_WARN" "0"
reset; verify_perf_tweaks  >/dev/null 2>&1; check "perf tweaks ok"   "$_VF_WARN" "0"
reset; verify_sysctl       >/dev/null 2>&1; check "sysctl ok"        "$_VF_WARN" "0"
reset; verify_catchup      >/dev/null 2>&1; check "catchup ok"       "$_VF_WARN" "0"
reset; verify_pohpin_timer >/dev/null 2>&1; check "timer ok"         "$_VF_WARN" "0"

echo "== env-class: verify_run resolves SOLANA_BIN absolute with HOME UNSET (systemd) =="
# verify runs inside Phase 8 via the resume service, where $HOME is empty. The
# source-time default would be '/.local/...'; verify_run must re-resolve HOME-free.
( unset SOLANA_BIN
  state_set solana_bin "/root/.local/share/solana/install/active_release/bin"
  HOME="" verify_run >/dev/null 2>&1
  echo "$SOLANA_BIN" ) >"$WORK/vbin" 2>&1
check "verify SOLANA_BIN from state (HOME unset)" "$(cat "$WORK/vbin")" "/root/.local/share/solana/install/active_release/bin"
check "verify never '/.local' (empty-HOME) path"  "$(grep -c '^/\.local' "$WORK/vbin")" "0"

echo "== bad system: failures + warnings detected =="
_vf_pid() { echo ""; }
reset; verify_process >/dev/null 2>&1; check "no process -> FAIL" "$_VF_FAIL" "1"
_vf_pid() { echo 12345; }
_vf_isolated() { echo "10,34"; }
reset; verify_isolation >/dev/null 2>&1; check "isolation mismatch -> FAIL" "$_VF_FAIL" "1"
_vf_isolated() { echo "1-2,10,25-26,34"; }
VF_PID=12345   # restore (the no-process test left it empty)
_vf_taskset() { echo "5"; }
reset; verify_poh_affinity >/dev/null 2>&1; check "poh wrong core -> warn" "$_VF_WARN" "1"
_vf_taskset() { echo "10"; }
mkcpus powersave powersave 4
reset; verify_perf_tweaks >/dev/null 2>&1; check "bad governor -> >=1 warn" "$([[ $_VF_WARN -ge 1 ]] && echo y || echo n)" "y"
mkcpus performance performance 4
_vf_catchup() { echo "85 slots behind (us:10 them:95)"; }
reset; verify_catchup >/dev/null 2>&1; check "behind -> warn" "$_VF_WARN" "1"
_vf_catchup() { echo "caught up (us:100 them:100)"; }

echo "== R10-2: the governor of every cpufreq CPU, not cpu0 alone =="
mkcpus performance ondemand 12
reset; verify_governors >"$WORK/gov" 2>&1
check "R10-2: cpu0 performance, 11 ondemand -> WARN with the count" "$_VF_WARN|$(grep -c 'governor = performance on 1/12 CPUs' "$WORK/gov")" "1|1"
check "R10-2: the others listed, in CPU order" "$(grep -c 'the others: cpu1(ondemand) cpu2(ondemand) .* cpu10(ondemand) cpu11(ondemand)$' "$WORK/gov")" "1"
mkcpus performance performance 12; mkdir -p "$WORK/cpu/cpu12"     # cpu12: no cpufreq dir, not counted
reset; verify_governors >"$WORK/gov" 2>&1
check "R10-2: all performance -> ok, CPUs without cpufreq skipped" "$_VF_WARN|$(grep -c 'governor = performance on 12/12 CPUs' "$WORK/gov")" "0|1"
rm -rf "$WORK/cpu"; mkdir -p "$WORK/cpu"
reset; verify_governors >"$WORK/gov" 2>&1
check "R10-2: no cpufreq CPU at all -> WARN" "$_VF_WARN|$(grep -c 'no cpufreq CPU found' "$WORK/gov")" "1|1"
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; verify_governors ) 2>&1 )
check "R10-2: real probe, empty sysfs, ERR trap -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"
mkcpus performance ondemand 4
verify_run >"$WORK/run" 2>&1
check "R10-2: verify_run (the post-reboot check) reads every CPU" "$(grep -c 'governor = performance on 1/4 CPUs' "$WORK/run")" "1"
mkcpus performance performance 4

echo "== R10-3: every mlx5 IRQ of the default-route NIC off the isolated CPUs, XDP cores included =="
# Fake /proc: pirq <n> <name> <effective cpu>. _vf_isolated says 1-2,10,25-26,34.
P="$WORK/proc"; export VF_PROC="$P"
pirq() { mkdir -p "$P/irq/$1"; echo "$3" >"$P/irq/$1/effective_affinity_list"
    printf ' %s:  0  0  IR-PCI-MSIX-%s  0-edge  %s\n' "$1" "${2#*@pci:}" "$2" >>"$P/interrupts"; }
ip()      { echo "default via 10.0.0.1 dev enp133s0f0np0 proto static"; }
ethtool() { printf 'driver: mlx5_core\nbus-info: %s\n' "${MOCK_BUS-0000:85:00.0}"; }
state_set nic_driver mlx5_core; state_set xdp_cores 1-2      # as on the rc9 box: exempts nothing
# The rc9 box after the old map (§9): comp10/25-28 moved, comp1/comp2 kept on the
# XDP cores 1/2, comp34 left on CPU34; the other port's comp0 is put on an
# isolated CPU — not this NIC's, not flagged.
rm -rf "$P"; mkdir -p "$P"; : >"$P/interrupts"
pirq 253 mlx5_async0@pci:0000:85:00.0 20; pirq 254 mlx5_comp0@pci:0000:85:00.0 0
pirq 256 mlx5_async0@pci:0000:85:00.1 21; pirq 257 mlx5_comp0@pci:0000:85:00.1 10
for i in $(seq 1 47); do pirq $((260 + i)) "mlx5_comp$i@pci:0000:85:00.0" "$i"; done
for p in 270:11 285:7 286:8 287:9 288:12; do echo "${p#*:}" >"$P/irq/${p%:*}/effective_affinity_list"; done
reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3b: the rc9 box (§9): comp1, comp2 on the XDP cores and comp34 -> WARN naming the three" \
    "$_VF_WARN|$(grep -c 'isolated CPUs: mlx5_comp1(irq 261)->cpu1 mlx5_comp2(irq 262)->cpu2 mlx5_comp34(irq 294)->cpu34 (' "$WORK/nicirq")" "1|1"
verify_run >"$WORK/run" 2>&1
check "R10-3: verify_run (the post-reboot check) runs it" "$(grep -c 'mlx5_comp34(irq 294)->cpu34' "$WORK/run")" "1"
echo 26 >"$P/irq/286/effective_affinity_list"; echo 10,34 >"$P/irq/253/effective_affinity_list"
reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3: every one listed, once each, in /proc/interrupts order" \
    "$(grep -c 'CPUs: mlx5_async0(irq 253)->cpu10 mlx5_comp1(irq 261)->cpu1 mlx5_comp2(irq 262)->cpu2 mlx5_comp26(irq 286)->cpu26 mlx5_comp34(irq 294)->cpu34 (' "$WORK/nicirq")" "1"
# What the R10-3b script leaves on that box: comp1, 2, 10, 25, 26, 34 on 3 4 5 6 7 8.
for p in 253:20 261:3 262:4 270:5 285:6 286:7 287:27 288:28 294:8; do echo "${p#*:}" >"$P/irq/${p%:*}/effective_affinity_list"; done
reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3b: none on an isolated CPU -> ok" "$_VF_WARN|$(grep -c 'none of 49 on an isolated CPU$' "$WORK/nicirq")" "0|1"
echo 1 >"$P/irq/275/effective_affinity_list"
reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3: an IRQ on an XDP core (comp15 on CPU1) -> WARN naming it" "$_VF_WARN|$(grep -c 'isolated CPUs: mlx5_comp15(irq 275)->cpu1 (' "$WORK/nicirq")" "1|1"
echo 15 >"$P/irq/275/effective_affinity_list"
MOCK_BUS=0000:99:00.0; reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3: no mlx5 IRQ of that PCI address -> WARN" "$_VF_WARN|$(grep -c 'none found for enp133s0f0np0 (pci 0000:99:00.0)' "$WORK/nicirq")" "1|1"
MOCK_BUS=""; reset; verify_nic_irqs >"$WORK/nicirq" 2>&1; unset MOCK_BUS
check "R10-3: no PCI address -> WARN" "$_VF_WARN|$(grep -c 'no PCI address for enp133s0f0np0' "$WORK/nicirq")" "1|1"
ip() { :; }; reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3: no default-route NIC -> WARN" "$_VF_WARN|$(grep -c 'mlx5 IRQs: no default-route NIC' "$WORK/nicirq")" "1|1"
ip() { echo "default via 10.0.0.1 dev enp133s0f0np0 proto static"; }
state_set nic_driver bnxt_en; reset; verify_nic_irqs >"$WORK/nicirq" 2>&1
check "R10-3: not mlx5 -> no check, no output" "$_VF_WARN|$(wc -c <"$WORK/nicirq" | tr -d ' ')" "0|0"
state_set nic_driver mlx5_core; export VF_PROC="$WORK/noproc"
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; verify_nic_irqs ) 2>&1 )
check "R10-3: real probe, no /proc/interrupts, ERR trap -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"
export VF_PROC="$P"; state_clear nic_driver

echo "== R10-5: the XDP UMEM's huge pages =="
# meminfo and solana.log lines as on the rc9 box (§18: chk-18.txt, chk-18b.txt);
# the start line is the one jito logs first (execute.rs:161).
export VF_MEMINFO="$WORK/meminfo"; mkdir -p "$WORK/solhome"; state_set solana_home "$WORK/solhome"
meminfo() { printf 'HugePages_Total:    %s\nHugePages_Free:     %s\nHugePages_Rsvd:        0\nHugepagesize:       2048 kB\n' "$1" "$1" >"$VF_MEMINFO"; }
START='[2026-10-05T14:37:40.101Z INFO  agave_validator::commands::run::execute] Starting validator with: ['
FELL='[2026-10-05T14:37:41.896259110Z WARN  agave_xdp::tx_loop] huge page alloc failed, falling back to regular page size'
state_set xdp_hugepages 32; meminfo 0
printf '%s\n' "$START" "$FELL" "$FELL" "$START" "$FELL" "$FELL" >"$WORK/solhome/solana.log"
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: the rc9 box: 0 huge pages, 2 fallbacks since the last start -> 2 WARN" \
    "$_VF_WARN|$(grep -c 'HugePages_Total = 0 (expected >= 32' "$WORK/hp")|$(grep -c 'regular pages: 2 .huge page alloc failed. since the last start' "$WORK/hp")" "2|1|1"
meminfo 32; printf '%s\n' "$START" >>"$WORK/solhome/solana.log"
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: 32 reserved, a clean start after the fallbacks -> ok, ok" \
    "$_VF_WARN|$(grep -c 'HugePages_Total = 32 (>= 32' "$WORK/hp")|$(grep -c 'no .huge page alloc failed. since the last start' "$WORK/hp")" "0|1|1"
meminfo 31
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: 31 < 32 -> WARN" "$_VF_WARN|$(grep -c 'HugePages_Total = 31 (expected >= 32' "$WORK/hp")" "1|1"
meminfo x
OUT=$( ( reset; verify_hugepages; echo "warn=$_VF_WARN" ) 2>&1 )
check "R10-5: HugePages_Total not a number -> WARN with it, no crash under set -u" "$(grep -c 'HugePages_Total = x (expected >= 32' <<<"$OUT")|$(grep -c '^warn=' <<<"$OUT")" "1|1"
# A day after the start: solana.log rotated (daily), no start line and no fallback in it.
meminfo 32; printf '%s\n' '[2026-10-06T00:00:05.120Z INFO  solana_metrics::metrics] datapoint: a line after the rotation' >"$WORK/solhome/solana.log"
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: rotated log, no start line in it -> fallback not checked (said), neither ok nor WARN" \
    "$_VF_WARN|$(grep -c 'the XDP huge page fallback is not checked' "$WORK/hp")|$(grep -c 'no .huge page alloc failed. since the last start' "$WORK/hp")" "0|1|0"
rm -f "$WORK/solhome/solana.log"
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: no log -> fallback not checked (said), not a WARN" "$_VF_WARN|$(grep -c 'the XDP huge page fallback is not checked' "$WORK/hp")" "0|1"
printf '%s\n' "$START" "$FELL" >"$WORK/solhome/solana.log"
verify_run >"$WORK/run" 2>&1
check "R10-5: verify_run (the post-reboot check) runs it" "$(grep -c 'regular pages: 1 ' "$WORK/run")" "1"
state_clear xdp_hugepages
reset; verify_hugepages >"$WORK/hp" 2>&1
check "R10-5: XDP off (nothing reserved) -> no check, no output" "$_VF_WARN|$(wc -c <"$WORK/hp" | tr -d ' ')" "0|0"
state_set xdp_hugepages 32; export VF_MEMINFO="$WORK/nomeminfo"; state_set solana_home "$WORK/nosolhome"
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; verify_hugepages ) 2>&1 )
check "R10-5: real probes, no meminfo, no log, ERR trap -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"
state_clear xdp_hugepages; state_clear solana_home; export VF_MEMINFO="$WORK/meminfo"

echo "== R10-6: identity — on the sync key is a WARN that names both cases =="
STK=kBi4uaoKafaLnLz7yjSScDDBTSH3riu7rGRm56txbNu; SYN=SyncPk1111111111111111111111111111111111111
LIVE=""; _vf_identity() { printf '%s' "$LIVE"; }; _vf_sync_pubkey() { printf '%s' "$SYN"; }
state_clear staked_pubkey
LIVE=$SYN; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: no staked pubkey recorded -> skipped, no warn" "$_VF_WARN|$(grep -c 'identity check skipped' "$WORK/id")" "0|1"
state_set staked_pubkey "$STK"
LIVE=$STK; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: live == staked -> ok"             "$_VF_WARN|$(grep -c "running on the staked identity $STK" "$WORK/id")" "0|1"
LIVE=$SYN; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: live == sync -> WARN"             "$_VF_WARN|$(grep -c 'NOT voting as staked' "$WORK/id")" "1|1"
check "R10-6: the WARN names both cases"        "$(grep -c 'expected before the swap; after a swap it means a restart reverted the identity' "$WORK/id")" "1"
LIVE=AnotherPk11111111111111111111111111111111111; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: neither staked nor sync -> WARN"  "$_VF_WARN|$(grep -c 'is neither the staked' "$WORK/id")" "1|1"
LIVE=""; reset; verify_identity >"$WORK/id" 2>&1
check "R10-6: no answer from getIdentity -> WARN" "$_VF_WARN|$(grep -c 'did not answer' "$WORK/id")" "1|1"
state_clear staked_pubkey

echo "== R10-10: no core dumps (the validator's memory holds its identity key) =="
reset; verify_limits >"$WORK/lim" 2>&1
check "R10-10: core 0/0 -> ok"                 "$(grep -cF 'core dump limit (soft/hard) = 0/0' "$WORK/lim")" "1"
check "R10-10: coredump_filter 00000010 -> ok" "$(grep -cF 'coredump_filter = 00000010' "$WORK/lim")" "1"
# 00000033 is the kernel default, measured on the rc9 box.
_vf_coredump_filter() { echo 00000033; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: coredump_filter 00000033 -> warn" "$_VF_WARN" "1"
_vf_coredump_filter() { echo 00000010; }
_vf_proc_limits() { printf 'Max core file size        unlimited   unlimited   bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: core unlimited -> warn" "$_VF_WARN" "1"
# Soft 0 / hard unlimited was measured on the rc9 box: the process may raise it.
_vf_proc_limits() { printf 'Max core file size        0           unlimited   bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
reset; verify_limits >/dev/null 2>&1; check "R10-10: core soft 0 / hard unlimited -> warn" "$_VF_WARN" "1"
_vf_proc_limits() { printf 'Max core file size        0           0           bytes\nMax open files            2000000     2000000     files\nMax locked memory         unlimited   unlimited   bytes\n'; }
# The real probes, on a pid that cannot exist, under DeePloy's ERR trap: a probe
# that fails inside $( ) would print a stray "[FAIL] line N" (ERR-NOISE-SUBST).
NOISE=$( ( unset _DEEPLOY_VERIFY_SOURCED
           # shellcheck source-path=SCRIPTDIR source=../lib/verify.sh
           source "$ROOT/lib/verify.sh"
           set -E; deeploy_init_traps; trap - EXIT; VF_PID=999999999; verify_limits ) 2>&1 )
check "R10-10: real probes, no such pid -> no stray [FAIL] line" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"

echo "== R10-4: catchup — two bounded getSlot reads, never 'solana catchup' =="
# getSlot mock: the node (127.0.0.1) answers $US, the cluster $THEM; DOWN = no
# answer (curl's exit for a refused connection).
curl() { local url=${!#} a
    case "$url" in http://127.0.0.1:*) a=$US ;; *) a=$THEM ;; esac
    [[ "$a" != DOWN ]] || return 7
    printf '{"jsonrpc":"2.0","result":%s,"id":1}\n' "$a"; }
# Through a pipe, 'solana catchup' prints nothing while the node is behind: its
# spinner is not drawn off a terminal. This stub does the same until it is
# killed, and appends its PID to $STUBS.
STUBS="$WORK/stubs"; : >"$STUBS"; mkdir -p "$WORK/bin"
printf '#!/bin/bash\necho $$ >>"%s"\nexec sleep 120\n' "$STUBS" >"$WORK/bin/solana"; chmod +x "$WORK/bin/solana"
# within <secs> <ERE> <cmd...>: runs <cmd> in the background and prints the
# first line of its output matching <ERE> as soon as there is one, or nothing
# after <secs>; then kills <cmd> and every stub still waiting.
within() {
    local secs=$1 re=$2 out="$WORK/within.out" pid i; shift 2
    "$@" >"$out" 2>&1 &
    pid=$!
    for (( i = 0; i < secs * 10; i++ )); do
        grep -qE "$re" "$out" && break
        command sleep 0.1
    done
    { kill -KILL "$pid"; wait "$pid"; xargs kill -KILL <"$STUBS"; } 2>/dev/null
    : >"$STUBS"
    grep -m1 -E "$re" "$out"
}
# verify_catchup with the real probe: verify.sh sourced again, in the
# background subshell only.
real_catchup() { unset _DEEPLOY_VERIFY_SOURCED
    # shellcheck source-path=SCRIPTDIR source=../lib/verify.sh
    source "$ROOT/lib/verify.sh"
    SOLANA_BIN="$WORK/bin" verify_catchup; }
US=10 THEM=95
check "behind, 'solana' silent -> a WARN within 5 s" "$(grep -c 'not caught up: 85 slots behind (us:10 them:95)$' <<<"$(within 5 'caught up' real_catchup)")" "1"
US=100 THEM=100
check "caught up -> ok, with both slots"             "$(grep -c '\[OK\] catchup: caught up (us:100 them:100)$' <<<"$(within 5 'caught up' real_catchup)")" "1"
US=99 THEM=100
check "1 behind -> ok (the CLI's window is 4)"       "$(grep -c '\[OK\] catchup: caught up (us:99 them:100)$' <<<"$(within 5 'caught up' real_catchup)")" "1"
US=DOWN THEM=95
check "the node's RPC silent -> a WARN that says so" "$(grep -c "not caught up: no slot from the node's RPC at http://127.0.0.1:8899$" <<<"$(within 5 'caught up' real_catchup)")" "1"
unset -f curl

echo "== verify_run summary =="
verify_run >/dev/null 2>&1; check "all-good verify_run passes" "$?" "0"
_vf_isolated() { echo "wrong-set"; }
verify_run >/dev/null 2>&1; check "verify_run with a FAIL returns 1" "$?" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
