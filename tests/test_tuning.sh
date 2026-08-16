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

# Parameterized AMD topology: physical core c (c < total/2) -> "c,c+total/2".
MOCK_TOTAL=48
_cpu_total()    { echo "$MOCK_TOTAL"; }
_cpu_siblings() { local c=$1 half=$((MOCK_TOTAL/2)); if (( c < half )); then echo "$c,$((c+half))"; else echo "$((c-half)),$c"; fi; }
systemctl()  { :; }
sysctl()     { :; }
update-grub(){ :; }

iso() { MOCK_TOTAL=$1 _isolation_compute "$1" "$2" "$3"; }   # sets _ISO_SET / _ISO_IRQ

echo "== list helpers =="
check "_expand_list ranges" "$(_expand_list '1-2,10,25-26' | tr '\n' ' ')" "1 2 10 25 26 "
check "_compress_ranges"    "$(printf '%s\n' 0 1 3 4 5 7 | _compress_ranges)" "0-1,3-5,7"

echo "== isolation math vs the memo's hand-built variants =="
iso 48 2 0;  check "POH2/48  set"  "$_ISO_SET" "2,26";              check "POH2/48  irq"  "$_ISO_IRQ" "0-1,3-25,27-47"
iso 48 10 0; check "POH10/48 set"  "$_ISO_SET" "10,34";             check "POH10/48 irq"  "$_ISO_IRQ" "0-9,11-33,35-47"
iso 32 2 0;  check "POH2/32  set"  "$_ISO_SET" "2,18";              check "POH2/32  irq"  "$_ISO_IRQ" "0-1,3-17,19-31"
iso 32 10 0; check "POH10/32 set"  "$_ISO_SET" "10,26";             check "POH10/32 irq"  "$_ISO_IRQ" "0-9,11-25,27-31"
iso 64 2 0;  check "POH2/64  set"  "$_ISO_SET" "2,34";              check "POH2/64  irq"  "$_ISO_IRQ" "0-1,3-33,35-63"
iso 192 2 0; check "POH2/192 set"  "$_ISO_SET" "2,98";              check "POH2/192 irq"  "$_ISO_IRQ" "0-1,3-97,99-191"

echo "== isolation math with reserved XDP cores (memo LAST_clear variants) =="
iso 48 10 2; check "POH10+2xdp set" "$_ISO_SET" "1-2,10,25-26,34"; check "POH10+2xdp irq" "$_ISO_IRQ" "0,3-9,11-24,27-33,35-47"
iso 48 10 4; check "POH10+4xdp set" "$_ISO_SET" "1-4,10,25-28,34"; check "POH10+4xdp irq" "$_ISO_IRQ" "0,5-9,11-24,29-33,35-47"

echo "== _default_poh_core / _valid_cpu =="
MOCK_TOTAL=48; check "default PoH core = 10 (prod)"        "$(_default_poh_core 48)" "10"
MOCK_TOTAL=8;  check "small box falls back to 3rd primary" "$(_default_poh_core 8)"  "2"
MOCK_TOTAL=48
check_true  "valid cpu 2/48"  "_valid_cpu 2 48"
check_false "cpu 48/48 invalid" "_valid_cpu 48 48"
check_false "cpu abc invalid"   "_valid_cpu abc 48"

echo "== DEFAULT layout: PoH=10 + XDP=2 (retransmit supported) -> 1-2,10,25-26,34 =="
state_set retransmit_supported 1
unset POH_CORE XDP_CORES_COUNT; MOCK_TOTAL=48
tuning_resolve_config >/dev/null 2>&1
check "default POH_CORE=10"       "$POH_CORE" "10"
check "default XDP_CORES_COUNT=2" "$XDP_CORES_COUNT" "2"
_isolation_compute "$TUNE_TOTAL" "$POH_CORE" "$XDP_CORES_COUNT"
check "default isolated set"  "$_ISO_SET" "1-2,10,25-26,34"
check "default irqaffinity"   "$_ISO_IRQ" "0,3-9,11-24,27-33,35-47"
check "default xdp_cores"     "$_ISO_XDP" "1-2"
# Without retransmit support, no XDP cores reserved -> simple 10,34.
state_set retransmit_supported 0
unset POH_CORE XDP_CORES_COUNT
tuning_resolve_config >/dev/null 2>&1
check "unsupported NIC: XDP=0" "$XDP_CORES_COUNT" "0"
_isolation_compute "$TUNE_TOTAL" "$POH_CORE" "$XDP_CORES_COUNT"
check "unsupported isolated set" "$_ISO_SET" "10,34"

echo "== _grub_strip_managed preserves base, drops managed =="
STRIP=$(_grub_strip_managed "quiet vendor ds=vendor console=tty0 amd_pstate=passive isolcpus=domain,managed_irq,2,26 nohz_full=2,26 rcu_nocbs=2,26 irqaffinity=0-1,3-25,27-47 nvme_core.default_ps_max_latency_us=0")
check "strip keeps base only" "$STRIP" "quiet vendor ds=vendor console=tty0"

echo "== tuning_grub: compose, preserve base, idempotent, state =="
G="$WORK/grub"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=ttyS0,115200n8 console=tty0"' 'GRUB_TIMEOUT=5' >"$G"
MOCK_TOTAL=48; TUNE_TOTAL=48; POH_CORE=2; XDP_CORES_COUNT=0; GRUB_FILE="$G"
tuning_grub >/dev/null 2>&1
EXPECT='GRUB_CMDLINE_LINUX_DEFAULT="quiet vendor ds=vendor console=ttyS0,115200n8 console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,2,26 nohz_full=2,26 rcu_nocbs=2,26 irqaffinity=0-1,3-25,27-47"'
check "grub line composed (base preserved + isolation appended)" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")" "$EXPECT"
check "unrelated grub lines untouched" "$(grep -c '^GRUB_TIMEOUT=5' "$G")" "1"
BEFORE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")
tuning_grub >/dev/null 2>&1   # re-run
check "grub idempotent (strip+readd = same)" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$G")" "$BEFORE"
check "reboot_required recorded" "$(state_get reboot_required)" "1"
check "isolated_set recorded"    "$(state_get isolated_set)" "2,26"
check "irqaffinity recorded"     "$(state_get irqaffinity)" "0-1,3-25,27-47"

echo "== I1: tuning_grub CLEARS the stale reboot_done/reboot_pending latch on re-arm =="
# A sanctioned re-tune re-arms reboot_required; the stale completion latch must be
# cleared so the reboot boundary forces a fresh reboot instead of proceeding to
# Phase 8 against the OLD, still-live kernel isolation.
state_set reboot_done "stale-ts"; state_set reboot_pending "stale-ts"
POH_CORE=2 tuning_grub >/dev/null 2>&1
check "I1: reboot_required re-armed"     "$(state_get reboot_required)" "1"
check "I1: stale reboot_done CLEARED"    "$(state_has reboot_done && echo y || echo n)" "n"
check "I1: stale reboot_pending CLEARED" "$(state_has reboot_pending && echo y || echo n)" "n"

echo "== POH change 2 -> 10 re-run: exactly one isolcpus, new value, no concat =="
GC="$WORK/grubchg"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0"' >"$GC"
MOCK_TOTAL=48; TUNE_TOTAL=48; XDP_CORES_COUNT=0; GRUB_FILE="$GC"
POH_CORE=2;  tuning_grub >/dev/null 2>&1
POH_CORE=10; tuning_grub >/dev/null 2>&1
GLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GC")
check "exactly one isolcpus= token"     "$(grep -o 'isolcpus=' <<<"$GLINE" | wc -l | tr -d ' ')"   "1"
check "exactly one irqaffinity= token"  "$(grep -o 'irqaffinity=' <<<"$GLINE" | wc -l | tr -d ' ')" "1"
check "isolcpus has NEW value 10,34"    "$(grep -c 'isolcpus=domain,managed_irq,10,34' "$GC")"      "1"
check "old value 2,26 fully gone"       "$(grep -c '2,26' "$GC")"                                   "0"

echo "== N13: GRUB read/write symmetry — both quote styles, duplicates collapse =="
# single-quoted provider file: base params must survive the rewrite (the old
# double-quote-only read returned empty -> console=ttyS0 was silently dropped).
GS="$WORK/grub_squote"
printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT='quiet console=ttyS0,115200n8'" >"$GS"
MOCK_TOTAL=48; TUNE_TOTAL=48; POH_CORE=2; XDP_CORES_COUNT=0; GRUB_FILE="$GS"
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
PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" tuning_perf >/dev/null 2>&1
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

echo "== H3: performance-tweaks runs Before=solana.service =="
check "perf unit Before=solana.service"              "$(grep -c '^Before=solana.service' "$WORK/perf.service")" "1"
check "perf unit dropped After=multi-user.target (would cycle)" "$(grep -c '^After=multi-user.target' "$WORK/perf.service")" "0"
check "perf unit enable semantics unchanged (WantedBy)" "$(grep -c 'WantedBy=multi-user.target' "$WORK/perf.service")" "1"

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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
