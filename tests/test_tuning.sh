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

echo "== G1: the generated grub.cfg is the source of truth, not what we wrote =="
# /etc/default/grub is an INPUT. grub-mkconfig sources /etc/default/grub.d/*.cfg
# after it, so a drop-in that assigns GRUB_CMDLINE_LINUX_DEFAULT replaces the line
# DeePloy just wrote, update-grub still exits 0, and the box reboots with no
# isolation. Only reading the output catches that.
GG="$WORK/grub_g1"; printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_TIMEOUT=5' >"$GG"
MOCK_TOTAL=48; TUNE_TOTAL=48; POH_CORE=2; XDP_CORES_COUNT=0; GRUB_FILE="$GG"; GRUBD_CLOBBER=""
state_clear reboot_required; state_clear isolated_set
tuning_grub >/dev/null 2>&1
check "G1: clean box -> tuning_grub succeeds"      "$?" "0"
check "G1: and the generated cfg carries isolcpus" \
      "$(grep -c 'isolcpus=domain,managed_irq,2,26' "$GCFG")" "1"
check "G1: reboot armed"                           "$(state_get reboot_required)" "1"
OUTG1=$(tuning_grub 2>&1 || true)
check "G1: and it says where it verified"          "$(grep -c 'survived grub-mkconfig' <<<"$OUTG1")" "1"

# The clobber: a drop-in wins, update-grub still exits 0, the input file is fine.
GRUBD_CLOBBER="console=tty1 console=ttyS0,115200n8"
state_clear reboot_required
( tuning_grub ) >/dev/null 2>&1
check "G1: drop-in clobbers the cmdline -> REFUSES" "$?" "1"
check "G1: and the input file still looks right"    "$(grep -c 'isolcpus=domain,managed_irq,2,26' "$GG")" "1"

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
GRUBD_CLOBBER="quiet isolcpus=domain,managed_irq,2,26"
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
