#!/usr/bin/env bash
# Self-contained tests for lib/preflight.sh — no root, no network, no live node.
# Every external probe is shadowed by a shell-function mock; /proc and
# os-release are fixtures. Each check is exercised in isolation via its counter
# deltas (_PF_HARD / _PF_WARN).
#
# The mock functions below shadow real commands and are invoked indirectly by
# the code under test, so disable the "function never invoked" check file-wide.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state"
export DEEPLOY_BACKUP_DIR="$WORK/backups"
export DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1
export DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/preflight.sh
source "$ROOT/lib/preflight.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
reset() { _PF_HARD=0; _PF_WARN=0; }
counts() { check "$1 [hard=$2 warn=$3]" "${_PF_HARD}/${_PF_WARN}" "$2/$3"; }

# Position in preflight_run, by name. Asserting a literal ordinal ("wired
# second") encodes a number instead of the requirement, and breaks the moment
# anything is inserted ahead of it — which is exactly what adding
# _pf_check_self_executable did. What actually matters is that the structural
# checks, the ones that cost nothing and can refuse before the box is touched,
# all run before the first measurement of the machine.
pf_index() {                                      # <check-name> -> its 1-based position
    sed -n '/^preflight_run()/,/^}/p' "$ROOT/lib/preflight.sh" \
        | grep -oE '^[[:space:]]+_pf_check_[a-z_]+' | tr -d ' ' \
        | grep -nx "$1" | cut -d: -f1
}


DRY_RUN=0 common_init

# ---- fixtures ---------------------------------------------------------------
mkfix() { printf '%s' "$2" >"$WORK/$1"; printf '%s' "$WORK/$1"; }
OSR_UBUNTU=$(mkfix os_ubuntu $'ID=ubuntu\nVERSION_ID="24.04"\n')
OSR_OLD=$(mkfix os_old      $'ID=ubuntu\nVERSION_ID="22.04"\n')
OSR_DEBIAN=$(mkfix os_deb   $'ID=debian\nVERSION_ID="12"\n')
CPU_GOOD=$(mkfix cpu_good   $'processor\t: 0\nmodel name\t: AMD EPYC 9354 32-Core Processor\nflags\t\t: fpu aes sse2 avx\nprocessor\t: 1\nflags\t\t: fpu aes\n')
CPU_BAD=$(mkfix cpu_bad     $'processor\t: 0\nmodel name\t: Tiny CPU\nflags\t\t: fpu sse2\nprocessor\t: 1\nflags\t\t: fpu\n')
MEM_BIG=$(mkfix mem_big     $'MemTotal:       395264000 kB\nSwapTotal:       2097152 kB\n')
MEM_SMALL=$(mkfix mem_small $'MemTotal:        16777216 kB\nSwapTotal:             0 kB\n')

echo "== _pf_base_disk =="
check "nvme partition -> base" "$(_pf_base_disk /dev/nvme0n1p2)" "nvme0n1"
check "nvme whole disk"        "$(_pf_base_disk /dev/nvme0n1)"   "nvme0n1"
check "sata partition -> base" "$(_pf_base_disk /dev/sda1)"      "sda"
check "virtio partition"       "$(_pf_base_disk vda2)"           "vda"

echo "== platform =="
uname() { echo x86_64; }
reset; OS_RELEASE_FILE="$OSR_UBUNTU" _pf_check_platform >/dev/null 2>&1; counts "ubuntu 24.04 x86_64" 0 0
reset; OS_RELEASE_FILE="$OSR_OLD"    _pf_check_platform >/dev/null 2>&1; counts "ubuntu 22.04 (warn)" 0 1
reset; OS_RELEASE_FILE="$OSR_DEBIAN" _pf_check_platform >/dev/null 2>&1; counts "debian (hard)"       1 0
uname() { echo aarch64; }
reset; OS_RELEASE_FILE="$OSR_UBUNTU" _pf_check_platform >/dev/null 2>&1; counts "aarch64 (hard)"      1 0
uname() { echo x86_64; }

echo "== cpu =="
# nproc IS present on real test hosts (coreutils) and would return the host's core
# count, overriding the cpuinfo fixture (tripped both boxes in mirror directions).
# Mock it to count the fixture's processors so the core-count cases are deterministic
# on any host. (F5)
nproc() { grep -c '^processor' "${PROC_CPUINFO:-/proc/cpuinfo}" 2>/dev/null || echo 0; }
reset; PROC_CPUINFO="$CPU_GOOD" PF_MIN_CORES=2 _pf_check_cpu >/dev/null 2>&1; counts "aes + enough cores" 0 0
reset; PROC_CPUINFO="$CPU_BAD"  PF_MIN_CORES=24 _pf_check_cpu >/dev/null 2>&1; counts "no aes + few cores" 0 2
unset -f nproc

echo "== memory =="
reset; PROC_MEMINFO="$MEM_BIG"   _pf_check_memory >/dev/null 2>&1; counts "377 GiB ok"   0 0
reset; PROC_MEMINFO="$MEM_SMALL" _pf_check_memory >/dev/null 2>&1; counts "16 GiB warn"  0 1

echo "== storage =="
export PROC_MDSTAT="$WORK/nomd"; : >"$WORK/nomd"   # deterministic: no RAID unless a case overrides
findmnt() { echo "/dev/nvme2n1p2"; }
lsblk()   { printf '%s\n' "nvme0n1 1.9T disk 0 Samsung_PM9A3" "nvme1n1 1.9T disk 0 Samsung_PM9A3" "nvme2n1 240G disk 0 BootSSD"; }
reset; _pf_check_storage >/dev/null 2>&1; counts "2 NVMe data disks ok" 0 0
check "data_disk_count recorded" "$(state_get data_disk_count)" "2"
lsblk() { printf '%s\n' "nvme0n1 1.9T disk 0 OnlyOne" "nvme2n1 240G disk 0 BootSSD"; }
reset; _pf_check_storage >/dev/null 2>&1; counts "1 NVMe data disk warn" 0 1

echo "== storage: software-RAID SYSTEM vs DATA-disk RAID (the fixed warn) =="
# OS on md0 (raid1 across sda2+sdb2); the 2 NVMe are the real data disks. The old
# code warned "single-volume root layout" and counted 4 data disks — both wrong.
RAIDSYS=$(mkfix mdstat_sys $'Personalities : [raid1]\nmd0 : active raid1 sdb2[1] sda2[0]\n      234419136 blocks super 1.2 [2/2] [UU]\n')
findmnt() { echo "/dev/md0"; }
lsblk()   { printf '%s\n' "sda 256G disk 0 SATA_A" "sdb 256G disk 0 SATA_B" "nvme0n1 1.9T disk 0 Samsung" "nvme1n1 1.9T disk 0 Samsung"; }
reset; PROC_MDSTAT="$RAIDSYS" _pf_check_storage >/dev/null 2>&1; counts "system-RAID: NO false warn" 0 0
check "system-RAID members excluded -> data_disk_count=2" "$(state_get data_disk_count)" "2"
# A RAID on NON-system disks DOES change Phase 3 (single data volume) -> a correct warn.
RAIDDATA=$(mkfix mdstat_data $'Personalities : [raid0]\nmd1 : active raid0 nvme0n1[0] nvme1n1[1]\n      blocks super 1.2\n')
findmnt() { echo "/dev/sda2"; }
lsblk()   { printf '%s\n' "sda 256G disk 0 BootSSD" "nvme0n1 1.9T disk 0 Samsung" "nvme1n1 1.9T disk 0 Samsung" "md1 3.8T raid0 0 "; }
reset; PROC_MDSTAT="$RAIDDATA" _pf_check_storage >/dev/null 2>&1; counts "data-RAID: warns (matches Phase 3)" 0 1

echo "== nic =="
ip() { case "$*" in *"route show default"*) echo "default via 10.0.0.1 dev enp1s0 proto static";;
                    *) echo "enp1s0 UP";; esac; }
ethtool() { echo "driver: mlx5_core"; }
reset; _pf_check_nic >/dev/null 2>&1; counts "mlx5: supported + zc" 0 0
check "mlx5 retransmit_supported=1" "$(state_get retransmit_supported)" "1"
check "mlx5 retransmit_zero_copy=1" "$(state_get retransmit_zero_copy)" "1"
ethtool() { echo "driver: bnxt_en"; }
reset; _pf_check_nic >/dev/null 2>&1; counts "bnxt: supported, NO zc" 0 0
check "bnxt retransmit_supported=1" "$(state_get retransmit_supported)" "1"
check "bnxt retransmit_zero_copy=0" "$(state_get retransmit_zero_copy)" "0"
ethtool() { echo "driver: r8169"; }
reset; _pf_check_nic >/dev/null 2>&1; counts "other driver: warn, disabled" 0 1
check "other retransmit_supported=0" "$(state_get retransmit_supported)" "0"
unset -f ethtool   # ethtool absent on host -> driver unknown
reset; _pf_check_nic >/dev/null 2>&1; counts "no ethtool -> warn" 0 1

echo "== time =="
timedatectl() { echo yes; }
reset; _pf_check_time >/dev/null 2>&1; counts "ntp synced ok" 0 0
timedatectl() { echo no; }
reset; _pf_check_time >/dev/null 2>&1; counts "not synced warn" 0 1

echo "== cluster / genesis =="
curl() { printf '%s' '{"jsonrpc":"2.0","result":"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d","id":1}'; }
reset; _pf_check_cluster >/dev/null 2>&1; counts "mainnet genesis ok" 0 0
curl() { printf '%s' '{"jsonrpc":"2.0","result":"WrongGenesisHash1111111111111111111111111111","id":1}'; }
reset; _pf_check_cluster >/dev/null 2>&1; counts "genesis mismatch hard" 1 0
curl() { printf ''; }
reset; _pf_check_cluster >/dev/null 2>&1; counts "rpc unreachable warn" 0 1

echo "== bandwidth (opt-in --net-test) =="
curl() { printf '125000000'; }   # 1000 Mbps
reset; NET_TEST=0 _pf_check_bandwidth >/dev/null 2>&1; counts "skipped without --net-test" 0 0
reset; NET_TEST=1 _pf_check_bandwidth >/dev/null 2>&1; counts "fast link ok (net-test)"     0 0
curl() { printf '1000000'; }     # 8 Mbps
reset; NET_TEST=1 PF_MIN_MBPS=200 _pf_check_bandwidth >/dev/null 2>&1; counts "slow link warn (net-test)" 0 1

echo "== ports =="
ss() { printf '%s\n' "tcp LISTEN 0 0 0.0.0.0:8899 0.0.0.0:*"; }
reset; _pf_check_ports >/dev/null 2>&1; counts "8899 in use warn" 0 1

echo "== existing install =="
state_set current-phase "3:Disk"
reset; _pf_check_existing >/dev/null 2>&1; counts "mid-phase resume warn" 0 1
state_clear current-phase

echo "== N8 follow-up: the checkout gate fires at PHASE 0, not at the reboot boundary =="
# The install-time gate sat in _install_setup_resume_service — reached only after
# the disk wipe and the 30-90 min build. The README's own path (clone as a user,
# then sudo) produces exactly the uid it refuses, so the documented flow used to
# hard-fail an hour in. Same predicate, now in the first seconds.
deeploy_path_uid()  { echo 0; }
deeploy_path_mode() { echo 755; }
reset; _pf_check_checkout >/dev/null 2>&1; counts "safe checkout -> no issue" 0 0
deeploy_path_uid() { echo 501; }             # the README's clone-as-user case
# Counter assertion runs in the CURRENT shell: a $( ) capture is a subshell, so
# the pf_bad increment would never reach _PF_HARD here and the check would pass
# against a no-op too (the same trap the N12 test fell into). Message captured
# in a separate run below.
reset; _pf_check_checkout >/dev/null 2>&1; counts "user-owned checkout -> BLOCKING" 1 0
CKOUT=$(_pf_check_checkout 2>&1 || true)
check "names the fix (chown -R root:root)" "$(grep -c 'chown -R root:root' <<<"$CKOUT")" "1"
check "explains the boot-time risk"        "$(grep -c 'as root at boot' <<<"$CKOUT")"   "1"
deeploy_path_uid() { echo 0; }
deeploy_path_mode() { echo 775; }
reset; _pf_check_checkout >/dev/null 2>&1; counts "group-writable checkout -> BLOCKING" 1 0
deeploy_path_mode() { echo 755; }
# and it is wired into preflight_run BEFORE anything else runs
check "wired first in preflight_run" \
    "$(grep -A2 '_PF_HARD=0; _PF_WARN=0' "$ROOT/lib/preflight.sh" | grep -c '_pf_check_checkout')" "1"

echo "== 7c1: _pf_check_self_executable (the installer itself, asked in phase 0) =="
# The reboot boundary sits between phase 7 and phase 8, so the resume unit is
# written AFTER the disks are erased (phase 3) and after the 30-90 minute build
# (phase 4). A checkout that lost its bit in delivery would pay all of that
# before being refused. Phase 0 is where the question costs nothing.
SELFX="$WORK/deeploy.sh"; printf '#!/bin/bash\n' >"$SELFX"
export DEEPLOY_SELF="$SELFX"
deeploy_path_mode() { echo 755; }
reset; _pf_check_self_executable >/dev/null 2>&1; counts "executable entry point -> clean" 0 0
deeploy_path_mode() { echo 644; }
reset; _pf_check_self_executable >/dev/null 2>&1; counts "entry point 644 -> BLOCKING" 1 0
SX=$(_pf_check_self_executable 2>&1 || true)
check "names the mode it found"        "$(grep -c 'is mode 644' <<<"$SX")" "1"
check "names the fix"                  "$(grep -c 'chmod +x' <<<"$SX")" "1"
check "says the disks go first"        "$(grep -c 'data disks already erased' <<<"$SX")" "1"
# Subject control: this must refuse for the bit, not for ownership. 644 is not
# group-writable, so the neighbouring predicate passes it — if this message ever
# said root-owned, the scenario would be measuring that one and reporting it here.
check "and it is NOT the ownership refusal" "$(grep -c 'root-owned' <<<"$SX")" "0"
# It runs before the box is measured at all: structural first, measurement after.
check "runs before the first measurement of the machine" \
      "$(( $(pf_index _pf_check_self_executable) < $(pf_index _pf_check_platform) ))" "1"
deeploy_path_mode() { echo 755; }
unset DEEPLOY_SELF

echo "== 7c2: _pf_check_tools (what runs after the disks are gone) =="
# The failure this check exists for: mkfs.xfs was called one line after
# blkdiscard, shipped in no package DeePloy installs, and was verified nowhere.
# The run erased both data disks and then died on "command not found".
have() { case " $PRESENT " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
PRESENT="${PF_REQUIRED_TOOLS[*]}"
reset; _pf_check_tools >/dev/null 2>&1; counts "every tool present -> clean" 0 0

# mkfs.xfs, mdadm, setcap and getcap come from lib/base.sh DEEPLOY_PACKAGES, which
# phase 1 installs — and phase 1 runs before phase 3. So their absence BEFORE
# phase 1 is not a refusal: the stock Ubuntu 22.04 image ships none of them, and
# refusing there turned a box that was going to work into a box that would not
# start. After phase 1 is marked done, the same absence means the install did not
# happen, and it is a refusal again. Both directions are asserted, because a
# conditional that only ever takes one branch is not a conditional.
PRESENT="${PF_REQUIRED_TOOLS[*]/mkfs.xfs/}"
state_clear phase-1 2>/dev/null || rm -f "$DEEPLOY_STATE_DIR/state.d/phase-1"
reset; _pf_check_tools >/dev/null 2>&1; counts "mkfs.xfs missing, phase 1 pending -> NOT blocking" 0 0
TOUT=$(_pf_check_tools 2>&1 || true)
check "  says phase 1 installs it"       "$(grep -c 'phase 1 installs those' <<<"$TOUT")" "1"
check "  and names the tool it means"    "$(grep -c 'mkfs.xfs' <<<"$TOUT")" "1"

mark_phase_done 1
# Counter in the CURRENT shell, message from a separate capture: a $( ) runs
# in a subshell, so a pf_bad inside one never reaches _PF_HARD here.
reset; _pf_check_tools >/dev/null 2>&1; counts "mkfs.xfs missing, phase 1 done -> BLOCKING" 1 0
TOUT=$(_pf_check_tools 2>&1 || true)
check "names the missing command"        "$(grep -c 'mkfs.xfs' <<<"$TOUT")" "1"
check "names the package that has it"    "$(grep -c 'xfsprogs' <<<"$TOUT")" "1"
check "says the disks go first"          "$(grep -c 'erased before any of them is used' <<<"$TOUT")" "1"
check "points at the phase, not at apt"  "$(grep -c 'install --only 1' <<<"$TOUT")" "1"
# Control the other way: a tool that is present must not be reported. Without
# this, a check that named every tool unconditionally would pass the three above.
check "and does not name a tool that IS present" "$(grep -c 'blkdiscard' <<<"$TOUT")" "0"

# The condition must not leak. blkdiscard comes from no package DeePloy installs,
# so it blocks whatever phase 1 has done — including before it has run at all.
state_clear phase-1 2>/dev/null || rm -f "$DEEPLOY_STATE_DIR/state.d/phase-1"
PRESENT="${PF_REQUIRED_TOOLS[*]/blkdiscard/}"
reset; _pf_check_tools >/dev/null 2>&1; counts "blkdiscard missing, phase 1 pending -> BLOCKING" 1 0
TOUT=$(_pf_check_tools 2>&1 || true)
check "  names blkdiscard"               "$(grep -c 'blkdiscard' <<<"$TOUT")" "1"
check "  and does not offer --only 1 for it" "$(grep -c 'install --only 1' <<<"$TOUT")" "0"

mark_phase_done 1
PRESENT="${PF_REQUIRED_TOOLS[*]/setcap/}"
reset; _pf_check_tools >/dev/null 2>&1; counts "setcap missing, phase 1 done -> BLOCKING" 1 0
TOUT=$(_pf_check_tools 2>&1 || true)
check "names libcap2-bin for setcap"     "$(grep -c 'libcap2-bin' <<<"$TOUT")" "1"
state_clear phase-1 2>/dev/null || rm -f "$DEEPLOY_STATE_DIR/state.d/phase-1"

# It must run while the disks are still intact — that is the whole point — and
# before the box is measured, so a missing tool is reported in seconds rather
# than after the bandwidth probe.
check "_pf_check_tools runs before the first measurement" \
      "$(( $(pf_index _pf_check_tools) < $(pf_index _pf_check_platform) ))" "1"
# Control: the index really is being read, and the ordering really is directional.
check "  and pf_index resolves a real position"  "$(pf_index _pf_check_platform | grep -cE '^[0-9]+$')" "1"
check "  and a later check does NOT precede it"  "$(( $(pf_index _pf_check_bandwidth) < $(pf_index _pf_check_platform) ))" "0"
unset -f have; unset PRESENT TOUT

echo "== 7c3: _pf_check_grub_dropins (what grub-mkconfig reads AFTER us) =="
# grub-mkconfig sources /etc/default/grub.d/*.cfg after /etc/default/grub, so a
# drop-in that ASSIGNS GRUB_CMDLINE_LINUX_DEFAULT replaces the isolation DeePloy
# writes — Ubuntu cloud images ship 50-cloudimg-settings.cfg doing exactly that.
# A warning, not a blocker: phase 2 reads the generated grub.cfg back and refuses
# before any reboot. This just puts the cause in front of the operator earlier.
# Assert the check EXISTS before asserting what it does: the "clean" cases below
# would otherwise pass against a missing function — calling one leaves the
# counters at 0/0, which is exactly what they expect.
check "the check exists at all" "$(type -t _pf_check_grub_dropins)" "function"
GRUBD="$WORK/grub.d"; mkdir -p "$GRUBD"; export GRUB_D_DIR="$GRUBD"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0"\n' >"$GRUBD/50-cloudimg-settings.cfg"
reset; _pf_check_grub_dropins >/dev/null 2>&1; counts "a clobbering drop-in -> WARN (not blocking)" 0 1
GOUT=$(_pf_check_grub_dropins 2>&1 || true)
check "names the offending file"      "$(grep -c '50-cloudimg-settings.cfg' <<<"$GOUT")" "1"
check "explains the ordering"         "$(grep -c 'AFTER /etc/default/grub' <<<"$GOUT")" "1"
check "says phase 2 will refuse"      "$(grep -c 'refuses rather than reboot' <<<"$GOUT")" "1"

# Appending is not clobbering. Without this control, a check that flagged every
# drop-in mentioning the variable would pass all four assertions above.
# shellcheck disable=SC2016  # the unexpanded text IS the fixture: this is what a
# real drop-in contains, and recognising it is what the check under test does.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT elevator=none"\n' >"$GRUBD/60-append.cfg"
rm -f "$GRUBD/50-cloudimg-settings.cfg"
reset; _pf_check_grub_dropins >/dev/null 2>&1; counts "a drop-in that APPENDS -> clean" 0 0
printf 'GRUB_TIMEOUT=3\n' >"$GRUBD/70-unrelated.cfg"
reset; _pf_check_grub_dropins >/dev/null 2>&1; counts "a drop-in touching other keys -> clean" 0 0
# And the ${...} spelling of the same append must not be read as a clobber.
# shellcheck disable=SC2016  # ditto, the braced spelling
printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} quiet"\n' >"$GRUBD/61-braces.cfg"
reset; _pf_check_grub_dropins >/dev/null 2>&1; counts "braced append -> clean" 0 0

export GRUB_D_DIR="$WORK/grub.d.absent"
reset; _pf_check_grub_dropins >/dev/null 2>&1; counts "no drop-in directory at all -> clean" 0 0
GOUT2=$(_pf_check_grub_dropins 2>&1 || true)
check "and says so rather than staying silent" "$(grep -c 'No .* drop-ins' <<<"$GOUT2")" "1"
unset GRUB_D_DIR

echo "== 7d: preflight_run HARD-GATES (_PF_HARD>0 -> abort; warns alone pass) =="
require_root() { :; }
# Silence every check preflight_run makes, DERIVED from preflight_run itself. A
# hand-written list here is a list that goes stale: a check added later is not
# stubbed, its real findings land in _PF_HARD, and this scenario — which is about
# the counter, not about any one check — starts failing for an unrelated reason.
# That is exactly what a new _pf_check_tools did the first time it was wired in.
stubbed=0
while read -r f; do
    eval "${f}() { :; }"; stubbed=$((stubbed + 1))
done < <(sed -n '/^preflight_run()/,/^}/p' "$ROOT/lib/preflight.sh" \
         | grep -oE '^[[:space:]]+_pf_check_[a-z_]+' | tr -d ' ')
check "7d: every check in preflight_run was stubbed" "$((stubbed >= 12))" "1"
_pf_check_platform() { pf_bad "synthetic blocking issue"; }
PFOUT=$( ( preflight_run ) 2>&1 ); PFRC=$?
check "7d: one hard issue -> preflight aborts (rc1)" "$PFRC" "1"
check "7d: abort message counts the blockers"        "$(grep -c 'Preflight found 1 blocking issue' <<<"$PFOUT")" "1"
_pf_check_platform() { pf_warn "soft issue only"; }
( preflight_run ) >/dev/null 2>&1
check "7d: warnings alone -> preflight passes (rc0)" "$?" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
