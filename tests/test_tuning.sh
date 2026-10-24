#!/usr/bin/env bash
# Self-contained tests for lib/tuning.sh — no root. CPU topology is mocked
# (sibling = c + total/2, the AMD SMT layout) so the isolation math can be
# checked 1:1 against the operator's hand-built GRUB variants. System files are
# written to temp paths; systemctl/sysctl/update-grub are mocked.
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
# shellcheck source-path=SCRIPTDIR source=../lib/tuning.sh
source "$ROOT/lib/tuning.sh"

PASS=0; FAIL=0
check()      { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false(){ if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
# POH_CORE was a setting of an older tuning.sh and nothing reads it now. Defined (empty) so that this suite, run against
# that older code, fails its checks instead of set -u ending the file at the first tuning_grub.
POH_CORE=""

# The real _cpu_total and _cpu_siblings, kept under other names before the mocks below replace them: the checks of how a box with a hole in
# its online list is counted and laid out call these.
eval "$(declare -f _cpu_total | sed '1s/^_cpu_total/_cpu_total_real/')"
eval "$(declare -f _cpu_siblings | sed '1s/^_cpu_siblings/_cpu_siblings_real/')"

# Parameterized AMD topology: physical core c (c < total/2) -> "c,c+total/2".
MOCK_TOTAL=48
_cpu_total()    { echo "$MOCK_TOTAL"; }
_cpu_siblings() { local c=$1 half=$((MOCK_TOTAL/2)); if (( c < half )); then echo "$c,$((c+half))"; else echo "$((c-half)),$c"; fi; }
systemctl()  { :; }
sysctl()     { :; }
# A faithful update-grub, because the module now reads its OUTPUT back. The real
# tool bakes GRUB_CMDLINE_LINUX_DEFAULT into the generated grub.cfg — and a
# /etc/default/grub.d drop-in can replace that value on the way, which is the
# whole failure this models. GRUB_CFG_CANDIDATES also keeps the check away from a
# real /boot/grub/grub.cfg: the ubuntu runner HAS one, so both an empty mock and a
# "file is missing" fixture would otherwise send the assertion to read the
# runner's own bootloader config and pass for the wrong reason.
GCFG="$WORK/grub.cfg"
GRUB_CFG_CANDIDATES=("$GCFG")
GRUBD_CLOBBER=""                 # non-empty = a drop-in assigns the cmdline instead
update-grub(){
    local line
    line=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "${GRUB_FILE:-/dev/null}" | tail -1)
    [[ -n "$GRUBD_CLOBBER" ]] && line="$GRUBD_CLOBBER"
    printf 'menuentry Ubuntu {\n\tlinux\t/boot/vmlinuz-6.8.0 root=UUID=deadbeef ro %s\n}\n' "$line" \
        >"$GCFG"
}

iso() { MOCK_TOTAL=$1 _isolation_compute "$1" "$2"; }   # <total> <xdp count>; sets _ISO_SET / _ISO_IRQ / _ISO_XDP

echo "== list helpers =="
check "_expand_list ranges" "$(_expand_list '1-2,10,25-26' | tr '\n' ' ')" "1 2 10 25 26 "
check "_compress_ranges"    "$(printf '%s\n' 0 1 3 4 5 7 | _compress_ranges)" "0-1,3-5,7"

echo "== _cpu_total counts the CPUs online, not the CPUs of the caller's affinity =="
# nproc is the CALLER's affinity: on a box booted with isolcpus that is online minus isolated. Box 2, 2026-10-24: nproc 42, nproc --all 48,
# online 0-47, and phase 2 wrote irqaffinity=0,3-24,27-41 (CPUs 42-47 missing). The stub is that caller; the fixtures are the kernel's list.
nproc() { echo 42; }
mkdir -p "$WORK/sys48" "$WORK/sysgap" "$WORK/sysone" "$WORK/sysbad" "$WORK/sysempty" "$WORK/nosys"
printf '0-47\n' >"$WORK/sys48/online";      printf '0-95\n' >"$WORK/sys48/present"       # present is the decoy: it is not what is online
printf '0-3,5-7\n' >"$WORK/sysgap/online";  printf '0\n' >"$WORK/sysone/online"
printf 'not a list\n' >"$WORK/sysbad/online"; : >"$WORK/sysempty/online"
{ for i in 0 1 2 3 4 5; do printf 'processor\t: %s\n' "$i"; done; } >"$WORK/cpuinfo6"
cpu_total_at() { CPU_SYSFS_ROOT=$1 PROC_CPUINFO="$WORK/cpuinfo6" _cpu_total_real; }          # <sysfs root>
check "online 0-47, the caller's affinity cut to 42: 48, not nproc's 42"       "$(cpu_total_at "$WORK/sys48")"    "48"
check "online 0-3,5-7 (CPU 4 offline): 8 = the highest online CPU + 1"         "$(cpu_total_at "$WORK/sysgap")"   "8"
check "online 0: 1"                                                             "$(cpu_total_at "$WORK/sysone")"   "1"
check "no list under the root: /proc/cpuinfo (6), not nproc's 42"              "$(cpu_total_at "$WORK/nosys")"    "6"
check "a list that is not a list: /proc/cpuinfo (6)"                           "$(cpu_total_at "$WORK/sysbad")"   "6"
check "an empty list: /proc/cpuinfo (6)"                                       "$(cpu_total_at "$WORK/sysempty")" "6"
unset -f nproc
# The real function on this machine, in a process of its own (no mock, no fixture): pinned to CPU 0 with taskset it must still count every CPU
# that is online. Where one CPU is all there is, nothing can differ, so that is "cannot measure", not a pass.
if [[ -r /sys/devices/system/cpu/online ]]; then
    ONLINE=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    # shellcheck disable=SC2016  # the text is for bash -c, which expands $1
    REAL='source "$1/lib/common.sh"; source "$1/lib/tuning.sh"; _cpu_total'
    if [[ "$ONLINE" =~ ^[0-9]+$ ]] && (( ONLINE > 1 )); then
        check "the real _cpu_total here: the $ONLINE CPUs online"                              "$(bash -c "$REAL" _ "$ROOT" 2>/dev/null)" "$ONLINE"
        if have taskset; then
            check "(control) nproc pinned to CPU 0 by taskset says 1: the affinity is cut"      "$(taskset -c 0 nproc 2>/dev/null)" "1"
            check "the real _cpu_total pinned to CPU 0 by taskset: still $ONLINE"               "$(taskset -c 0 bash -c "$REAL" _ "$ROOT" 2>/dev/null)" "$ONLINE"
        else FAIL=$((FAIL+1)); printf '  FAIL cannot measure: no taskset on this machine, so the affinity cannot be cut\n'; fi
    else FAIL=$((FAIL+1)); printf '  FAIL cannot measure: %s CPU online on this machine, so the affinity cannot differ from online\n' "${ONLINE:-?}"; fi
else
    printf '  note: no /sys/devices/system/cpu/online here (not Linux): the real-machine checks run on the Linux CI; the fixtures above run everywhere\n'
fi

echo "== isolation math: the XDP cores and their SMT siblings, from CPU 1 up =="
iso 48 1;  check "1 xdp/48  set" "$_ISO_SET" "1,25";      check "1 xdp/48  irq" "$_ISO_IRQ" "0,2-24,26-47";    check "1 xdp/48  xdp" "$_ISO_XDP" "1"
iso 48 2;  check "2 xdp/48  set" "$_ISO_SET" "1-2,25-26";  check "2 xdp/48  irq" "$_ISO_IRQ" "0,3-24,27-47";    check "2 xdp/48  xdp" "$_ISO_XDP" "1-2"
iso 48 4;  check "4 xdp/48  set" "$_ISO_SET" "1-4,25-28";  check "4 xdp/48  irq" "$_ISO_IRQ" "0,5-24,29-47";    check "4 xdp/48  xdp" "$_ISO_XDP" "1-4"
iso 32 2;  check "2 xdp/32  set" "$_ISO_SET" "1-2,17-18";  check "2 xdp/32  irq" "$_ISO_IRQ" "0,3-16,19-31";    check "2 xdp/32  xdp" "$_ISO_XDP" "1-2"
iso 64 2;  check "2 xdp/64  set" "$_ISO_SET" "1-2,33-34";  check "2 xdp/64  irq" "$_ISO_IRQ" "0,3-32,35-63";    check "2 xdp/64  xdp" "$_ISO_XDP" "1-2"
iso 192 2; check "2 xdp/192 set" "$_ISO_SET" "1-2,97-98";  check "2 xdp/192 irq" "$_ISO_IRQ" "0,3-96,99-191";   check "2 xdp/192 xdp" "$_ISO_XDP" "1-2"
# CPU 0 stays out: without --poh-pinned-cpu-core the client counts it as the PoH
# core and refuses XDP cores that include it (execute.rs 1515-1532). Its SMT
# sibling is no physical-core primary, so it is no XDP core either.
cpu_in() { _expand_list "$2" | grep -qx "$1"; }       # <cpu> <list>
for t in 8 32 48 64 192; do
    iso "$t" 3
    check_false "CPU 0 is never isolated ($t CPUs, 3 xdp)"                 "cpu_in 0 \"\$_ISO_SET\""
    check_false "CPU 0's SMT sibling is never an XDP core ($t CPUs)"       "cpu_in $((t / 2)) \"\$_ISO_XDP\""
    check_false "CPU 0's SMT sibling is not isolated either ($t CPUs)"     "cpu_in $((t / 2)) \"\$_ISO_SET\""
done
echo "== isolation math: no XDP cores, nothing isolated =="
iso 48 0; check "0 xdp/48: set"  "$_ISO_SET" "";  check "0 xdp/48: irq" "$_ISO_IRQ" "";  check "0 xdp/48: xdp" "$_ISO_XDP" ""
iso 48 ""; check "xdp count empty: nothing isolated" "$_ISO_SET|$_ISO_IRQ|$_ISO_XDP" "||"
# Stale values of an earlier call must not survive a call that isolates nothing.
iso 48 2; iso 48 0
check "a call with no XDP cores clears the earlier answer" "$_ISO_SET|$_ISO_IRQ|$_ISO_XDP" "||"
iso 2 4;  check "a box whose only core is CPU 0 has nothing to reserve" "$_ISO_SET|$_ISO_IRQ|$_ISO_XDP" "||"
iso 8 10; check "more XDP cores asked than the box has: every core but core 0" "$_ISO_SET|$_ISO_IRQ|$_ISO_XDP" "1-3,5-7|0,4|1-3"

echo "== no PoH core in phase 2 =="
check_false "_default_poh_core is gone" 'declare -F _default_poh_core >/dev/null'
check_false "_valid_cpu is gone"        'declare -F _valid_cpu >/dev/null'
check       "TUNING_DEFAULT_POH_CORE is gone" "${TUNING_DEFAULT_POH_CORE-<unset>}" "<unset>"

echo "== DEFAULT layout: XDP=2 (retransmit supported) -> 1-2,25-26, and no PoH question =="
rm -f "$WORK/asked" "$WORK/resolved"
state_set retransmit_supported 1
( ask() { printf '%s\n' "$1" >>"$WORK/asked"; REPLY=$2; }
  unset POH_CORE XDP_CORES_COUNT; MOCK_TOTAL=48
  tuning_resolve_config >/dev/null 2>&1
  printf '%s|%s\n' "$XDP_CORES_COUNT" "${POH_CORE:-<unset>}" >"$WORK/resolved" )
check "default XDP_CORES_COUNT=2, POH_CORE not set"   "$(cat "$WORK/resolved")" "2|<unset>"
check "the XDP question is asked"                       "$(grep -c 'XDP retransmit' "$WORK/asked")" "1"
check "no question names the PoH core"                 "$(grep -ci 'poh' "$WORK/asked")" "0"
check "no poh_core recorded in state"                  "$(state_get poh_core '<none>')" "<none>"
check "state records xdp_cores_count=2"                "$(state_get xdp_cores_count)" "2"
# A POH_CORE left in the environment (an older conf or habit) is not a setting: not
# validated, not recorded, and no reason to stop.
( export POH_CORE=999; tuning_resolve_config ) >/dev/null 2>&1
check "an invalid POH_CORE in the environment does not stop phase 2" "$?" "0"
check "and it is not recorded either"                  "$(state_get poh_core '<none>')" "<none>"
unset XDP_CORES_COUNT; TUNE_TOTAL=48; MOCK_TOTAL=48
_isolation_compute "$TUNE_TOTAL" 2
check "default isolated set"  "$_ISO_SET" "1-2,25-26"
check "default irqaffinity"   "$_ISO_IRQ" "0,3-24,27-47"
check "default xdp_cores"     "$_ISO_XDP" "1-2"
# Without retransmit support no XDP cores are reserved, and then nothing is isolated.
state_set retransmit_supported 0
( unset POH_CORE XDP_CORES_COUNT; MOCK_TOTAL=48
  tuning_resolve_config >/dev/null 2>&1
  printf '%s\n' "$XDP_CORES_COUNT" >"$WORK/resolved" )
check "unsupported NIC: XDP=0" "$(cat "$WORK/resolved")" "0"
_isolation_compute 48 0
check "unsupported NIC: nothing isolated" "$_ISO_SET|$_ISO_IRQ|$_ISO_XDP" "||"

echo "== _grub_strip_managed preserves base, drops managed =="
STRIP=$(_grub_strip_managed "quiet vendor ds=vendor console=tty0 amd_pstate=passive isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34 rcu_nocbs=1-2,10,25-26,34 irqaffinity=0,3-9,11-24,27-33,35-47 nvme_core.default_ps_max_latency_us=0")
check "strip keeps base only" "$STRIP" "quiet vendor ds=vendor console=tty0"

echo "== tuning_grub: compose, preserve base, idempotent, state =="
G="$WORK/grub"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=ttyS0,115200n8 console=tty0"' 'GRUB_TIMEOUT=5' >"$G"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=2; GRUB_FILE="$G"
tuning_grub >/dev/null 2>&1
EXPECT='GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=ttyS0,115200n8 console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,1-2,25-26 nohz_full=1-2,25-26 rcu_nocbs=1-2,25-26 irqaffinity=0,3-24,27-47"'
check "grub line composed (base preserved + isolation appended)" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")" "$EXPECT"
check "unrelated grub lines untouched" "$(grep -c '^GRUB_TIMEOUT=5' "$G")" "1"
BEFORE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")
tuning_grub >/dev/null 2>&1   # re-run
check "grub idempotent (strip+readd = same)" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")" "$BEFORE"
check "reboot_required recorded" "$(state_get reboot_required)" "1"
check "isolated_set recorded"    "$(state_get isolated_set)" "1-2,25-26"
check "irqaffinity recorded"     "$(state_get irqaffinity)" "0,3-24,27-47"
check "xdp_cores recorded"       "$(state_get xdp_cores)" "1-2"

echo "== I1: tuning_grub CLEARS the stale reboot_done/reboot_pending latch on re-arm =="
# A sanctioned re-tune re-arms reboot_required; the stale completion latch must be
# cleared so the reboot boundary forces a fresh reboot instead of proceeding to
# Phase 8 against the OLD, still-live kernel isolation.
state_set reboot_done "stale-ts"; state_set reboot_pending "stale-ts"
tuning_grub >/dev/null 2>&1
check "I1: reboot_required re-armed"     "$(state_get reboot_required)" "1"
check "I1: stale reboot_done CLEARED"    "$(state_has reboot_done && echo y || echo n)" "n"
check "I1: stale reboot_pending CLEARED" "$(state_has reboot_pending && echo y || echo n)" "n"

echo "== XDP cores change 2 -> 4 re-run: exactly one isolcpus, new value, no concat =="
GC="$WORK/grubchg"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0"' >"$GC"
MOCK_TOTAL=48; TUNE_TOTAL=48; GRUB_FILE="$GC"
XDP_CORES_COUNT=2; tuning_grub >/dev/null 2>&1
XDP_CORES_COUNT=4; tuning_grub >/dev/null 2>&1
GLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GC")
check "exactly one isolcpus= token"     "$(grep -o 'isolcpus=' <<<"$GLINE" | wc -l | tr -d ' ')"   "1"
check "exactly one irqaffinity= token"  "$(grep -o 'irqaffinity=' <<<"$GLINE" | wc -l | tr -d ' ')" "1"
check "isolcpus has NEW value 1-4,25-28" "$(grep -c 'isolcpus=domain,managed_irq,1-4,25-28' "$GC")"  "1"
check "old value 1-2,25-26 fully gone"  "$(grep -c '1-2,25-26' "$GC")"                              "0"

echo "== R1: over an older install the old isolation, PoH core and sibling included, is replaced =="
# What an older DeePloy left on a 48-CPU box: PoH core 10 (sibling 34) + XDP 1-2.
GO="$WORK/grub_old"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34 rcu_nocbs=1-2,10,25-26,34 irqaffinity=0,3-9,11-24,27-33,35-47"' 'GRUB_TIMEOUT=5' >"$GO"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=2; GRUB_FILE="$GO"
state_set reboot_done "2026-10-20T00:00:00Z"
tuning_grub >"$WORK/old.out" 2>&1
check "old install: exit 0" "$?" "0"
OLDL=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GO")
check "old install: the line is the base + the NEW parameters only" "$OLDL" \
    'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,1-2,25-26 nohz_full=1-2,25-26 rcu_nocbs=1-2,25-26 irqaffinity=0,3-24,27-47"'
check "old install: the PoH core and its sibling are gone (10,34)" "$(grep -c '10,34' "$GO")" "0"
check "old install: one isolcpus, one nohz_full, one rcu_nocbs, one irqaffinity" \
    "$(grep -o 'isolcpus=' <<<"$OLDL" | wc -l | tr -d ' ')$(grep -o 'nohz_full=' <<<"$OLDL" | wc -l | tr -d ' ')$(grep -o 'rcu_nocbs=' <<<"$OLDL" | wc -l | tr -d ' ')$(grep -o 'irqaffinity=' <<<"$OLDL" | wc -l | tr -d ' ')" "1111"
check "old install: unrelated lines kept" "$(grep -c '^GRUB_TIMEOUT=5' "$GO")" "1"
check "old install: the generated cfg has the new set and not the old one" \
    "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26 ' "$GCFG")|$(grep -c '10,34' "$GCFG")" "1|0"
check "old install: the step names the XDP cores and no PoH core"   "$(grep -c 'CPU isolation (XDP cores=2, total CPUs=48)' "$WORK/old.out")|$(grep -ci 'poh' "$WORK/old.out")" "1|0"
check "old install: says the change takes effect at the next planned reboot" "$(grep -c 'next planned reboot' "$WORK/old.out")" "1"
check "old install: and that a staked node goes through its standby first"   "$(grep -c 'a staked node: move it to the standby first' "$WORK/old.out")" "1"
check "old install: reboot re-armed, the stale latch cleared" \
    "$(state_get reboot_required)|$(state_has reboot_done && echo y || echo n)" "1|n"
# A run that has not been through the reboot gate (a fresh install) has no planned reboot to speak of.
state_clear reboot_done
tuning_grub >"$WORK/fresh.out" 2>&1
check "no reboot gate behind it yet: no 'next planned reboot' line" "$(grep -c 'next planned reboot' "$WORK/fresh.out")" "0"

echo "== phase 2 on a box that already boots with isolcpus: irqaffinity covers every online CPU =="
# Box 2, 2026-10-24: the caller's affinity is cut to 42 CPUs (nproc 42), the kernel's list says 0-47, and the box has the old isolation in GRUB.
GI="$WORK/grub_iso"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34 rcu_nocbs=1-2,10,25-26,34 irqaffinity=0,3-9,11-24,27-33,35-47"' >"$GI"
_cpu_total() { _cpu_total_real; }; nproc() { echo 42; }
MOCK_TOTAL=48; XDP_CORES_COUNT=2; GRUB_FILE="$GI"; CPU_SYSFS_ROOT="$WORK/sys48"
tuning_resolve_config >/dev/null 2>&1
check "TUNE_TOTAL: the 48 CPUs online, not the 42 of the caller's affinity" "$TUNE_TOTAL" "48"
tuning_grub >/dev/null 2>&1
check "the GRUB line: the XDP cores with their siblings, irqaffinity over all 48 CPUs" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GI")" \
      'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,1-2,25-26 nohz_full=1-2,25-26 rcu_nocbs=1-2,25-26 irqaffinity=0,3-24,27-47"'
check "state: the isolated set and the irqaffinity it recorded" "$(state_get isolated_set)|$(state_get irqaffinity)" "1-2,25-26|0,3-24,27-47"
unset CPU_SYSFS_ROOT; _cpu_total() { echo "$MOCK_TOTAL"; }; unset -f nproc

echo "== a CPU offline in the middle of the online list (0-9,11-47) =="
# A kernel's sysfs for a 48-CPU AMD box with CPU 10 offline: no topology directory for it (so _cpu_siblings falls back to the CPU itself), and its
# sibling 34 lists only itself. The caller's affinity is cut (nproc 41 = 47 online minus 6 isolated). Checked with the REAL _cpu_total and
# _cpu_siblings; the answers are recorded as the code gives them, including what it does with CPU 10, which is NOT hidden:
#   - CPU 10 stays in irqaffinity (0..total-1 minus the isolated): a boot parameter may name an offline CPU, so that is harmless;
#   - KNOWN GAP, v0.1.1 backlog ISOLATION-OFFLINE-CPU: _isolation_compute walks 0..total-1, not the online list, so an offline CPU among the
#     lowest physical-core primaries can be taken as an XDP core. It needs ten XDP cores here to reach CPU 10; no box and no CI has a hole.
mkdir -p "$WORK/sysgap48"; printf '0-9,11-47\n' >"$WORK/sysgap48/online"
for c in $(seq 0 47); do
    [[ $c == 10 ]] && continue
    mkdir -p "$WORK/sysgap48/cpu$c/topology"
    if (( c == 34 )); then sib="34"; elif (( c < 24 )); then sib="$c,$((c + 24))"; else sib="$((c - 24)),$c"; fi
    printf '%s\n' "$sib" >"$WORK/sysgap48/cpu$c/topology/thread_siblings_list"
done
GH="$WORK/grub_hole"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor"' >"$GH"
( _cpu_total() { _cpu_total_real; }; _cpu_siblings() { _cpu_siblings_real "$@"; }; nproc() { echo 41; }
  export CPU_SYSFS_ROOT="$WORK/sysgap48" MOCK_TOTAL=48
  tot=$(_cpu_total)
  _isolation_compute "$tot" 2;  printf '%s|%s|%s|%s\n' "$tot" "$_ISO_SET" "$_ISO_IRQ" "$_ISO_XDP" >"$WORK/gap_two"
  _isolation_compute "$tot" 10; printf '%s|%s|%s\n' "$_ISO_SET" "$_ISO_IRQ" "$_ISO_XDP" >"$WORK/gap_ten"
  XDP_CORES_COUNT=2 GRUB_FILE="$GH" tuning_resolve_config >/dev/null 2>&1
  XDP_CORES_COUNT=2 GRUB_FILE="$GH" tuning_grub >/dev/null 2>&1 )
check "online 0-9,11-47, affinity cut to 41: the total is 48 (highest online 47 + 1), not 47 (the number online) and not 41" \
      "$(cut -d'|' -f1 "$WORK/gap_two")" "48"
check "2 XDP cores: the isolated set, the irqaffinity (CPU 47 in it) and the XDP cores" "$(cut -d'|' -f2- "$WORK/gap_two")" "1-2,25-26|0,3-24,27-47|1-2"
check "CPU 47 is in irqaffinity" "$(cut -d'|' -f3 "$WORK/gap_two" | tr ',' '\n' | grep -c '^27-47$')" "1"
check "AS IT IS: the offline CPU 10 is listed in irqaffinity too (3-24 covers it)" "$(cut -d'|' -f3 "$WORK/gap_two")" "0,3-24,27-47"
check "the GRUB line over this box: isolcpus 1-2,25-26, irqaffinity 0,3-24,27-47" "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26 nohz_full=1-2,25-26 rcu_nocbs=1-2,25-26 irqaffinity=0,3-24,27-47"' "$GH")" "1"
check "KNOWN GAP (v0.1.1, ISOLATION-OFFLINE-CPU): with 10 XDP cores asked the offline CPU 10 is taken as the tenth, its sibling list being just itself" \
      "$(cut -d'|' -f1,3 "$WORK/gap_ten")" "1-10,25-33|1-10"

echo "== R1: no XDP cores -> nothing isolated, GRUB keeps its two fixed parameters =="
GN="$WORK/grub_noxdp"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0"' 'GRUB_TIMEOUT=5' >"$GN"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=0; GRUB_FILE="$GN"; GRUBD_CLOBBER=""
state_clear reboot_required; state_set isolated_set "stale"; state_set irqaffinity "stale"; state_set xdp_cores "stale"
tuning_grub >"$WORK/noxdp.out" 2>&1
check "no XDP cores: exit 0" "$?" "0"
check "no XDP cores: the line is the base + the two fixed parameters" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GN")" \
    'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0"'
check "no XDP cores: no isolcpus, nohz_full, rcu_nocbs or irqaffinity in /etc/default/grub" "$(grep -cE 'isolcpus|nohz_full|rcu_nocbs|irqaffinity' "$GN")" "0"
check "no XDP cores: none in the generated cfg either" "$(grep -cE 'isolcpus|nohz_full|rcu_nocbs|irqaffinity' "$GCFG")" "0"
check "no XDP cores: the read-back says it checked the fixed parameters" "$(grep -c 'amd_pstate and nvme_core survived grub-mkconfig' "$WORK/noxdp.out")" "1"
check "no XDP cores: the output says nothing is isolated" "$(grep -c 'nothing is isolated' "$WORK/noxdp.out")" "1"
check "no XDP cores: the step names the XDP cores and no PoH core" "$(grep -c 'CPU isolation (XDP cores=0, total CPUs=48)' "$WORK/noxdp.out")|$(grep -ci 'poh' "$WORK/noxdp.out")" "1|0"
check "no XDP cores: isolated_set, irqaffinity, xdp_cores are empty (stale values replaced)" \
    "$(state_get isolated_set)|$(state_get irqaffinity)|$(state_get xdp_cores)" "||"
check "no XDP cores: the reboot is armed all the same (the parameters need it)" "$(state_get reboot_required)" "1"
BEFORE_N=$(cat "$GN")
tuning_grub >/dev/null 2>&1
check "no XDP cores: a re-run changes nothing" "$(cat "$GN")" "$BEFORE_N"
# The same box after an older install: the old set is stripped and nothing replaces it.
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,10,34 nohz_full=10,34 rcu_nocbs=10,34 irqaffinity=0-9,11-33,35-47"' >"$GN"
tuning_grub >/dev/null 2>&1
check "no XDP cores over an older install: the old PoH-only set is stripped" \
    "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GN")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_pstate=passive nvme_core.default_ps_max_latency_us=0"'
# The read-back still guards the box: a drop-in that replaces the line loses the fixed parameters.
GRUBD_CLOBBER="console=tty1 console=ttyS0,115200n8"
state_clear reboot_required
( tuning_grub ) >"$WORK/noxdp-clobber.out" 2>&1
check "no XDP cores: a clobbering drop-in -> REFUSES" "$?" "1"
check "no XDP cores: and the refusal names the missing parameters" "$(grep -c 'does not carry amd_pstate=passive and nvme_core.default_ps_max_latency_us=0' "$WORK/noxdp-clobber.out")" "1"
check "no XDP cores: no reboot armed after the refusal" "$(state_get reboot_required)" ""
# ... each of the two fixed parameters is checked, not just one of them
for GRUBD_CLOBBER in "quiet amd_pstate=passive" "quiet nvme_core.default_ps_max_latency_us=0"; do
    state_clear reboot_required
    ( tuning_grub ) >/dev/null 2>&1
    check "no XDP cores: the line kept only '${GRUBD_CLOBBER#quiet }' -> REFUSES" "$?" "1"
done
GRUBD_CLOBBER=""
( DRY_RUN=1 tuning_grub ) >"$WORK/noxdp-dry.out" 2>&1
check "no XDP cores: dry-run says what it would verify" "$(grep -c 'would read the generated grub.cfg back and verify amd_pstate=passive' "$WORK/noxdp-dry.out")" "1"

echo "== N13: GRUB read/write symmetry — both quote styles, duplicates collapse =="
# single-quoted provider file: base params must survive the rewrite (the old
# double-quote-only read returned empty -> console=ttyS0 was silently dropped).
GS="$WORK/grub_squote"
printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT='quiet console=ttyS0,115200n8'" >"$GS"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=2; GRUB_FILE="$GS"
tuning_grub >/dev/null 2>&1
check "single-quoted: provider params preserved + merged" "$(grep -c 'quiet console=ttyS0,115200n8 amd_pstate=passive' "$GS")" "1"
check "single-quoted: exactly one cmdline line"           "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GS")" "1"
check "single-quoted: rewritten double-quoted"            "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT="' "$GS")" "1"
# duplicate-lines file: the read takes the LAST line (what GRUB honors); the
# write collapses ALL lines to ONE at the FIRST line's position.
GD="$WORK/grub_dup"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_TIMEOUT=5' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0"' >"$GD"
GRUB_FILE="$GD"
tuning_grub >/dev/null 2>&1
check "duplicates: collapsed to exactly one line"   "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GD")" "1"
check "duplicates: LAST line's provider params won" "$(grep -c 'console=ttyS0' "$GD")" "1"
check "duplicates: line sits at the FIRST position" "$(head -1 "$GD" | grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=')" "1"
check "duplicates: unrelated line preserved"        "$(grep -c '^GRUB_TIMEOUT=5' "$GD")" "1"
# PROVEN-PATH GUARDRAIL: the canonical single-line double-quoted fixture must
# produce a BYTE-IDENTICAL file to what the old ensure_line edit produced.
GB="$WORK/grub_canon"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=ttyS0,115200n8 console=tty0"' 'GRUB_TIMEOUT=5' >"$GB"
GRUB_FILE="$GB"
tuning_grub >/dev/null 2>&1
printf '%s\n' "$EXPECT" 'GRUB_TIMEOUT=5' >"$WORK/grub_expected"
check_true "canonical fixture: byte-identical file" "cmp -s \"$GB\" \"$WORK/grub_expected\""

echo "== writers produce expected content =="
CPUFREQ_DEFAULT_FILE="$WORK/cpufrequtils" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" tuning_perf >/dev/null 2>&1
check "perf script governor"   "$(grep -c 'scaling_governor' "$WORK/perf.sh")" "1"
check_true "perf script +x"    "[[ -x \"$WORK/perf.sh\" ]]"
check "perf service oneshot"   "$(grep -c 'Type=oneshot' "$WORK/perf.service")" "1"
SYSCTL_FILE="$WORK/21.conf" SYSCTL_SERVICE_FILE="$WORK/sysctl.service" tuning_sysctl >/dev/null 2>&1
check "sysctl udp buffer"      "$(grep -c 'net.core.rmem_max=134217728' "$WORK/21.conf")" "1"
check "sysctl congestion"      "$(grep -c 'tcp_congestion_control=westwood' "$WORK/21.conf")" "1"
check "sysctl nr_open"         "$(grep -c 'fs.nr_open=2000000' "$WORK/21.conf")" "1"
# Phase 2 must contain ONLY always-valid keys — no fs.xfs.* (moved to Phase 3).
check "Phase 2 has NO fs.xfs key (moved to disk.sh)" "$(grep -c 'fs.xfs' "$WORK/21.conf")" "0"

echo "== N10: the boot sysctl unit tolerates kernel-absent keys (-e) =="
# plain 'sysctl -p' fails the unit on EVERY boot on kernels without
# tcp_low_latency (removed >=4.14) or the westwood module.
check "sysctl unit ExecStart uses -e -p"    "$(grep -c 'ExecStart=/usr/sbin/sysctl -e -p' "$WORK/sysctl.service")" "1"
check "sysctl unit: no plain '-p' ExecStart" "$(grep -c 'ExecStart=/usr/sbin/sysctl -p' "$WORK/sysctl.service")" "0"

echo "== SYSCTL-ORDER: the boot sysctl unit runs Before=solana.service =="
# It re-applies 21-agave-validator.conf after network.target and local-fs.target;
# with no order against solana.service the validator could start before that.
check "sysctl unit Before=solana.service" "$(grep -cx 'Before=solana.service' "$WORK/sysctl.service")" "1"
check "sysctl unit: After= unchanged, no multi-user.target (would cycle)" \
      "$(grep -cx 'After=network.target local-fs.target' "$WORK/sysctl.service")|$(grep -c '^After=multi-user.target' "$WORK/sysctl.service")" "1|0"

echo "== H3: performance-tweaks runs Before=solana.service =="
check "perf unit Before=solana.service"              "$(grep -c '^Before=solana.service' "$WORK/perf.service")" "1"
check "perf unit dropped After=multi-user.target (would cycle)" "$(grep -c '^After=multi-user.target' "$WORK/perf.service")" "0"
check "perf unit enable semantics unchanged (WantedBy)" "$(grep -c 'WantedBy=multi-user.target' "$WORK/perf.service")" "1"
echo "== R10-2: the cpufrequtils boot script sets performance too, and runs first =="
check "R10-2: /etc/default/cpufrequtils names performance" "$(grep -c '^GOVERNOR="performance"$' "$WORK/cpufrequtils")" "1"
check "R10-2: perf unit After=cpufrequtils.service"        "$(grep -c '^After=cpufrequtils.service$' "$WORK/perf.service")" "1"
cp "$WORK/cpufrequtils" "$WORK/cpufreq.1" 2>/dev/null || true
CPUFREQ_DEFAULT_FILE="$WORK/cpufrequtils" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" tuning_perf >/dev/null 2>&1
check "R10-2: a re-run leaves the file byte-identical" "$(cmp -s "$WORK/cpufrequtils" "$WORK/cpufreq.1" && echo same || echo differs)" "same"
# The operator's file: other lines stay, ONE GOVERNOR= line at the first one's place.
printf '%s\n' '# GOVERNOR="ondemand"' 'MAX_SPEED="3000000"' 'GOVERNOR="ondemand"' 'MIN_SPEED="0"' '  GOVERNOR="powersave"' >"$WORK/cpufreq.op"
CPUFREQ_DEFAULT_FILE="$WORK/cpufreq.op" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" tuning_perf >/dev/null 2>&1
check "R10-2: an operator's file keeps its lines, one GOVERNOR= line" "$(tr '\n' '|' <"$WORK/cpufreq.op")" '# GOVERNOR="ondemand"|MAX_SPEED="3000000"|GOVERNOR="performance"|MIN_SPEED="0"|'
printf '%s\n' 'ENABLE="true"' >"$WORK/cpufreq.op"
CPUFREQ_DEFAULT_FILE="$WORK/cpufreq.op" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" tuning_perf >/dev/null 2>&1
check "R10-2: an operator's file without GOVERNOR= gets it appended" "$(tr '\n' '|' <"$WORK/cpufreq.op")" 'ENABLE="true"|GOVERNOR="performance"|'

echo "== R10-5: huge pages for the XDP UMEM =="
check "R10-5: 2 queues, rings 1024/1024 -> 32"   "$(_tuning_xdp_hugepages 2 1024 1024)" "32"
check "R10-5: 2 queues, rings 512/512 -> 16"     "$(_tuning_xdp_hugepages 2 512 512)" "16"
check "R10-5: 2 queues, rings 4096/4096 -> 128" "$(_tuning_xdp_hugepages 2 4096 4096)" "128"
check "R10-5: 1 queue, rings 511/511 -> 8 (a part of a page counts whole)" "$(_tuning_xdp_hugepages 1 511 511)" "8"
# ethtool -g of the rc9 box (§18, chk-18.txt): current 1024/1024, maximum 8192.
printf 'Ring parameters for enp133s0f0np0:\nPre-set maximums:\nRX:\t\t\t8192\nRX Mini:\t\tn/a\nRX Jumbo:\t\tn/a\nTX:\t\t\t8192\nTX push buff len:\tn/a\nCurrent hardware settings:\nRX:\t\t\t1024\nRX Mini:\t\tn/a\nRX Jumbo:\t\tn/a\nTX:\t\t\t1024\nRX Buf Len:\t\tn/a\nCQE Size:\t\tn/a\nTX Push:\t\toff\nRX Push:\t\toff\nTX push buff len:\tn/a\nTCP data split:\t\toff\n' >"$WORK/rings"
ip()      { echo "default via 10.0.0.1 dev enp133s0f0np0 proto static"; }
ethtool() { [[ "$1 $2" == "-g enp133s0f0np0" ]] && cat "$WORK/rings"; }
state_set retransmit_supported 1; state_set xdp_cores 1-2
SYSCTL_FILE="$WORK/21x.conf" SYSCTL_SERVICE_FILE="$WORK/sysctlx.service" tuning_sysctl >/dev/null 2>&1
check "R10-5: XDP on, the rc9 box's rings -> vm.nr_hugepages=32 in the file and in state" "$(grep -cx 'vm.nr_hugepages=32' "$WORK/21x.conf")|$(state_get xdp_hugepages "")" "1|32"
state_set xdp_cores ""
SYSCTL_FILE="$WORK/21x.conf" SYSCTL_SERVICE_FILE="$WORK/sysctlx.service" tuning_sysctl >/dev/null 2>&1
check "R10-5: no XDP cores reserved -> no vm.nr_hugepages, nothing in state" "$(grep -c 'nr_hugepages' "$WORK/21x.conf")|$(state_get xdp_hugepages "")" "0|"
state_set xdp_cores 1-2; state_set retransmit_supported 0
SYSCTL_FILE="$WORK/21x.conf" SYSCTL_SERVICE_FILE="$WORK/sysctlx.service" tuning_sysctl >/dev/null 2>&1
check "R10-5: XDP off (retransmit unsupported) -> no vm.nr_hugepages, nothing in state" "$(grep -c 'nr_hugepages' "$WORK/21x.conf")|$(state_get xdp_hugepages "")" "0|"
state_set retransmit_supported 1; ethtool() { return 1; }
( set -Eeuo pipefail; deeploy_init_traps; trap - EXIT
  SYSCTL_FILE="$WORK/21y.conf" SYSCTL_SERVICE_FILE="$WORK/sysctly.service" tuning_sysctl ) >"$WORK/out" 2>&1
check "R10-5: rings unreadable, set -Eeuo pipefail + ERR trap -> survives, no stray [FAIL], 1024/1024 counted (32), a warning" \
    "$?|$(grep -cE '\[FAIL\] line [0-9]+' "$WORK/out")|$(grep -cx 'vm.nr_hugepages=32' "$WORK/21y.conf")|$(grep -c 'ring sizes unreadable' "$WORK/out")" "0|0|1|1"
ip() { return 1; }; rm -f "$WORK/21y.conf"
( set -Eeuo pipefail; deeploy_init_traps; trap - EXIT
  SYSCTL_FILE="$WORK/21y.conf" SYSCTL_SERVICE_FILE="$WORK/sysctly.service" tuning_sysctl ) >"$WORK/out" 2>&1
check "R10-5: no default route, set -Eeuo pipefail + ERR trap -> survives, no stray [FAIL], 1024/1024 counted (32)" \
    "$?|$(grep -cE '\[FAIL\] line [0-9]+' "$WORK/out")|$(grep -cx 'vm.nr_hugepages=32' "$WORK/21y.conf")" "0|0|1"
unset -f ip ethtool; state_set retransmit_supported 0; state_clear xdp_hugepages

echo "== Phase 2 sysctl: tolerant apply does NOT abort under set -Eeuo on a box w/o XFS =="
# Reproduce the real-box crash conditions: production flags + a sysctl that
# rejects fs.xfs.* (subtree absent). Even if a stale key were present, the run
# must survive; with the key removed it simply applies cleanly.
sysctl() { if [[ "$1" == "-w" ]]; then case "$2" in fs.xfs.*) return 1;; *) return 0;; esac; fi; }
( set -Eeuo pipefail
  SYSCTL_FILE="$WORK/21b.conf" SYSCTL_SERVICE_FILE="$WORK/sysctl2.service" tuning_sysctl ) >/dev/null 2>&1
check "tuning_sysctl survives set -Eeuo pipefail (no XFS loaded)" "$?" "0"

echo "== RESUME: re-running Phase 2 over an OLD config drops the bad fs.xfs key =="
# The box has the OLD 21-agave-validator.conf from the failed run (with the bad
# XFS key). Phase 2 re-runs on --resume; write_file must REWRITE it XFS-free,
# not rely solely on the apply-tolerance.
OLDCONF="$WORK/21-old.conf"
printf '%s\n' 'net.core.rmem_max=134217728' 'fs.nr_open=2000000' 'fs.xfs.xfssyncd_centisecs=10000' >"$OLDCONF"
check "precondition: old config HAS the bad key" "$(grep -c 'fs.xfs' "$OLDCONF")" "1"
SYSCTL_FILE="$OLDCONF" SYSCTL_SERVICE_FILE="$WORK/sysctl3.service" tuning_sysctl >/dev/null 2>&1
check "resume rewrote config: fs.xfs key GONE"   "$(grep -c 'fs.xfs' "$OLDCONF")" "0"
check "resume kept the good keys (rmem_max)"     "$(grep -c 'net.core.rmem_max=134217728' "$OLDCONF")" "1"
unset -f sysctl
printf '[Manager]\n' >"$WORK/system.conf"
LIMITS_FILE="$WORK/limits.conf" SYSTEM_CONF="$WORK/system.conf" tuning_limits >/dev/null 2>&1
check "limits nofile"          "$(grep -c 'nofile 2000000' "$WORK/limits.conf")" "1"
check "system.conf nofile"     "$(grep -c 'DefaultLimitNOFILE=2000000' "$WORK/system.conf")" "1"
LIMITS_FILE="$WORK/limits.conf" SYSTEM_CONF="$WORK/system.conf" tuning_limits >/dev/null 2>&1   # idempotent
check "system.conf nofile not duplicated" "$(grep -c 'DefaultLimitNOFILE' "$WORK/system.conf")" "1"

echo "== G1: the generated grub.cfg is the source of truth, not what we wrote =="
# /etc/default/grub is an INPUT. grub-mkconfig sources /etc/default/grub.d/*.cfg
# after it, so a drop-in that assigns GRUB_CMDLINE_LINUX_DEFAULT replaces the line
# DeePloy just wrote, update-grub still exits 0, and the box reboots with no
# isolation. Only reading the output catches that.
GG="$WORK/grub_g1"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_TIMEOUT=5' >"$GG"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=2; GRUB_FILE="$GG"; GRUBD_CLOBBER=""
state_clear reboot_required; state_clear isolated_set
tuning_grub >/dev/null 2>&1
check "G1: clean box -> tuning_grub succeeds"      "$?" "0"
check "G1: and the generated cfg carries isolcpus" \
      "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26' "$GCFG")" "1"
check "G1: reboot armed"                           "$(state_get reboot_required)" "1"
OUTG1=$(tuning_grub 2>&1 || true)
check "G1: and it says where it verified"          "$(grep -c 'survived grub-mkconfig' <<<"$OUTG1")" "1"

# The clobber: a drop-in wins, update-grub still exits 0, the input file is fine.
GRUBD_CLOBBER="console=tty1 console=ttyS0,115200n8"
state_clear reboot_required
( tuning_grub ) >/dev/null 2>&1
check "G1: drop-in clobbers the cmdline -> REFUSES" "$?" "1"
check "G1: and the input file still looks right"    "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26' "$GG")" "1"

# The refusal must name the drop-in on THIS box, found at that moment — not a
# filename the repo remembers. Fixture is deliberately not 50-cloudimg-settings:
# a hardcoded hint would pass an assertion naming that file and fail this one.
GDIR="$WORK/grub.d"; mkdir -p "$GDIR"; export GRUB_D_DIR="$GDIR"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1"\n' >"$GDIR/90-vendor-override.cfg"
OUTG2=$( ( tuning_grub ) 2>&1 || true )
check "G1: refusal names the drop-in it FOUND"  "$(grep -c '90-vendor-override.cfg' <<<"$OUTG2")" "1"
check "G1: and names no file it did not find"   "$(grep -c '50-cloudimg' <<<"$OUTG2")" "0"
# An appending drop-in is not a cause, so it must not be named either.
# shellcheck disable=SC2016  # unexpanded on purpose: that is what the file holds
printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT ro"\n' >"$GDIR/91-append.cfg"
OUTG2b=$( ( tuning_grub ) 2>&1 || true )
check "G1: an appending drop-in is not blamed"  "$(grep -c '91-append.cfg' <<<"$OUTG2b")" "0"
# And with no clobbering drop-in at all the refusal must say the cause is
# elsewhere rather than blame grub.d for something that is not there.
rm -f "$GDIR/90-vendor-override.cfg"
OUTG2c=$( ( tuning_grub ) 2>&1 || true )
check "G1: no clobberer -> says the cause is elsewhere" \
      "$(grep -c 'the cause is elsewhere' <<<"$OUTG2c")" "1"
unset GRUB_D_DIR
check "G1: NO reboot armed after the refusal"       "$(state_get reboot_required)" ""

# Partial application is not application: isolcpus present, nohz_full gone.
GRUBD_CLOBBER="quiet isolcpus=domain,managed_irq,1-2,25-26"
( tuning_grub ) >/dev/null 2>&1
check "G1: isolcpus without nohz_full -> REFUSES"   "$?" "1"
OUTG3=$( ( tuning_grub ) 2>&1 || true )
check "G1: and says partial is not applied" "$(grep -c 'partially applied' <<<"$OUTG3")" "1"

# No grub.cfg anywhere. The path depends on BIOS vs EFI, so this is an unanswered
# question, not an inapplicable check — it must refuse, never pass quietly.
GRUBD_CLOBBER=""
GRUB_CFG_CANDIDATES=("$WORK/nothing-here.cfg")   # and nothing falls back to /boot
( update-grub(){ :; }; tuning_grub ) >/dev/null 2>&1
check "G1: no generated grub.cfg -> REFUSES"        "$?" "1"
OUTG4=$( ( update-grub(){ :; }; tuning_grub ) 2>&1 || true )
check "G1: and calls it unanswered, not inapplicable" \
      "$(grep -c 'not that it does not apply\|unanswered question' <<<"$OUTG4")" "1"
# Control both ways: with the file back, the same call must succeed — otherwise
# every assertion above would pass against a function that always refused.
GRUB_CFG_CANDIDATES=("$GCFG")
state_clear reboot_required
tuning_grub >/dev/null 2>&1
check "G1: generated cfg back -> succeeds again"    "$?" "0"

# The pinning above only proves something if the DEFAULT list is the real one:
# a module that looked nowhere would pass every assertion in this section.
check "G1: the default candidate list is the real /boot locations" \
      "$(declare -f _grub_generated_cfg | grep -c '/boot/grub/grub.cfg')" "1"
check "G1: and a pinned list wins over it"        "$(_grub_generated_cfg)" "$GCFG"

# Dry-run writes nothing, so there is nothing to read back. That is not the same
# as skipping a check whose subject exists.
rm -f "$GCFG"
( DRY_RUN=1 tuning_grub ) >/dev/null 2>&1
check "G1: dry-run does not refuse on a missing cfg" "$?" "0"
OUTG5=$( ( DRY_RUN=1 tuning_grub ) 2>&1 || true )
check "G1: and says it WOULD verify"  "$(grep -c 'would read the generated grub.cfg' <<<"$OUTG5")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
