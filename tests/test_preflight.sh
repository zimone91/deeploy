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
# nproc is absent on the test host -> falls back to counting cpuinfo (2 procs).
reset; PROC_CPUINFO="$CPU_GOOD" PF_MIN_CORES=2 _pf_check_cpu >/dev/null 2>&1; counts "aes + enough cores" 0 0
reset; PROC_CPUINFO="$CPU_BAD"  PF_MIN_CORES=24 _pf_check_cpu >/dev/null 2>&1; counts "no aes + few cores" 0 2

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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
