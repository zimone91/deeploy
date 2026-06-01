#!/usr/bin/env bash
# Self-contained tests for lib/disk.sh — NO real disks. lsblk/findmnt/blkid/
# mountpoint/mdadm and every destructive command (blkdiscard/mkfs.xfs/mount/
# swapoff/umount) are mocked; mountpoints/symlink/fstab are temp paths.
#
# Headline (the RAID/eligibility fix): a box whose OS is on md-RAID1 across
# sda+sdb, plus a SATA data disk and 2 clean NVMe, must resolve to candidates =
# exactly the 2 NVMe — sda/sdb/md0 excluded as system, the SATA disk shown but
# not selectable — and map accounts/ledger onto the NVMe, never the system disks.
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
# Sandbox every path disk.sh would touch.
export LEDGER_MOUNT="$WORK/ledger" ACCOUNTS_MOUNT="$WORK/accounts" SOLANA_LINK="$WORK/solana" FSTAB_FILE="$WORK/fstab"
export DATA_MOUNT="$WORK/data"
export XFS_SYSCTL_FILE="$WORK/22-xfs.conf" XFS_MODLOAD_FILE="$WORK/modload-xfs.conf"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/disk.sh
source "$ROOT/lib/disk.sh"

PASS=0; FAIL=0
check()      { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

DRY_RUN=0 common_init
: >"$FSTAB_FILE"
CALLS="$WORK/calls"; : >"$CALLS"

# --- shared mocks ------------------------------------------------------------
require_root() { :; }                                            # bypass root gate (tested in common)
blkid()      { local d=${!#}; echo "U-${d##*/}"; }
sysctl()     { echo "sysctl $*" >>"$CALLS"; return 0; }          # XFS tuning apply (Phase 3)
blkdiscard() { echo "blkdiscard $*" >>"$CALLS"; }
mkfs.xfs()   { echo "mkfs.xfs $*"   >>"$CALLS"; }
mount()      { echo "mount $*"      >>"$CALLS"; }
swapoff()    { echo "swapoff $*"    >>"$CALLS"; }
umount()     { echo "umount $*"     >>"$CALLS"; }
systemctl()  { echo "systemctl $*"  >>"$CALLS"; }
mdadm()      { echo "mdadm $*"      >>"$CALLS"; }

# Topology is driven by these three knobs; lsblk/findmnt/mountpoint read them.
LSBLK_ENUM=""               # NAME SIZE TYPE ROTA MODEL lines (whole disks)
MP_A=""; MP_L=""            # mountpoints reported "active" by mountpoint -q
_mp_for()   { case "$1" in *) printf '';; esac; }       # per-device subtree mountpoints (overridden)
_size_for() { case "$1" in */sd?) echo 256060514304;; *) echo 2000398934016;; esac; }

lsblk() {
    local last=${!#}
    case "$*" in
        *"NAME,SIZE,TYPE,ROTA,MODEL"*) printf '%s\n' "$LSBLK_ENUM" ;;
        *"-nr -o MOUNTPOINT"*) _mp_for "$last" ;;
        *"-nr -o FSTYPE"*)     printf '' ;;
        *"-b -o SIZE"*)        _size_for "$last" ;;
        *"-o MODEL"*)          echo "MockModel" ;;
        *) echo "  (device tree for $last)" ;;
    esac
}
mountpoint() { local p=${!#}; case "$p" in "$MP_A"|"$MP_L") return 0;; *) return 1;; esac; }

# ============================================================================
echo "== detection primitives =="
check "nvme part -> base"    "$(_disk_base /dev/nvme0n1p3)" "nvme0n1"
check "nvme whole -> base"   "$(_disk_base /dev/nvme0n1)"   "nvme0n1"
check "sda part -> base"     "$(_disk_base /dev/sda2)"      "sda"
check_true "nvme0n1 is NVMe" "_disk_is_nvme nvme0n1"
check_true "sda is NOT NVMe" "! _disk_is_nvme sda"

# ============================================================================
echo "== HEADLINE: md-RAID1 system on sda/sdb + SATA data + 2 clean NVMe =="
LSBLK_ENUM='sda 256060514304 disk 0 SATA_SSD_A
sdb 256060514304 disk 0 SATA_SSD_B
sdc 4000787030016 disk 0 SATA_HDD_DATA
nvme0n1 2000398934016 disk 0 Samsung_PM9A3
nvme1n1 2000398934016 disk 0 Samsung_PM9A3'
_mp_for() { case "$1" in
    */sda) printf '/\n';;                # sda2 -> md0 -> /
    */sdb) printf '/boot/efi\n/\n';;     # sdb1 -> /boot/efi ; sdb2 -> md0 -> /
    */md0) printf '/\n';;
    *) printf '';; esac; }
findmnt() { echo "/dev/md0"; }           # root source IS the array (the buggy case)
export PROC_MDSTAT="$WORK/mdstat"
printf 'Personalities : [raid1]\nmd0 : active raid1 sdb2[1] sda2[0]\n      234419136 blocks super 1.2 [2/2] [UU]\n' >"$PROC_MDSTAT"

_disk_scan_raid
check "no data-NVMe array (system RAID excluded)" "$_DISK_DATA_ARRAY" ""
_disk_classify
check "eligible count = 2"                    "${#_DISK_ELIGIBLE[@]}"   "2"
check "eligible = the 2 NVMe"                 "${_DISK_ELIGIBLE[*]}"    "nvme0n1 nvme1n1"
check "system disks = sda sdb (RAID members)" "${_DISK_SYSTEM[*]}"      "sda sdb"
check_true "sda NOT in eligible"              "! _disk_in_list sda ${_DISK_ELIGIBLE[*]}"
check_true "sdb NOT in eligible"              "! _disk_in_list sdb ${_DISK_ELIGIBLE[*]}"
check "SATA sdc shown not-eligible (not NVMe)" "$(printf '%s\n' "${_DISK_INELIGIBLE[@]}" | grep -c '^sdc|not NVMe')" "1"

unset ACCOUNTS_DISK LEDGER_DISK
_disk_resolve >/dev/null 2>&1
check "layout two-nvme"        "$DISK_LAYOUT"     "two-nvme"
check "accounts on NVMe"       "$ACCOUNTS_DISK"   "/dev/nvme0n1"
check "ledger on NVMe"         "$LEDGER_DISK"     "/dev/nvme1n1"
check_true "accounts NEVER sda/sdb" "[[ \"$ACCOUNTS_DISK\" != /dev/sda && \"$ACCOUNTS_DISK\" != /dev/sdb ]]"
check_true "ledger NEVER sda/sdb"   "[[ \"$LEDGER_DISK\" != /dev/sda && \"$LEDGER_DISK\" != /dev/sdb ]]"
check "accounts_disk recorded" "$(state_get accounts_disk)" "/dev/nvme0n1"

echo "== backstop: a --config-provided SYSTEM disk is REFUSED =="
( ACCOUNTS_DISK=/dev/sda LEDGER_DISK=/dev/nvme1n1 _disk_resolve ) >/dev/null 2>&1
check "config system disk refused (exit non-zero)" "$?" "1"
( ACCOUNTS_DISK=/dev/sdc LEDGER_DISK=/dev/nvme1n1 _disk_resolve ) >/dev/null 2>&1
check "config SATA (non-NVMe) disk refused"        "$?" "1"

echo "== SAFETY: non-interactive NEVER auto-wipes =="
: >"$CALLS"; MP_A=""; MP_L=""
ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1
( _disk_two_nvme ) >/dev/null 2>&1; RC=$?
check "wipe aborts (exit non-zero)" "$RC" "1"
check "NO blkdiscard issued"        "$(grep -c blkdiscard "$CALLS")" "0"
check "NO mkfs issued"              "$(grep -c 'mkfs.xfs' "$CALLS")" "0"

echo "== destructive sequence (after explicit yes) =="
: >"$CALLS"; : >"$FSTAB_FILE"; rm -f "$SOLANA_LINK"
require_yes() { return 0; }                                       # simulate operator typing 'yes'
ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 MP_A="" MP_L="" _disk_two_nvme >/dev/null 2>&1
check "blkdiscard accounts"  "$(grep -c 'blkdiscard -f /dev/nvme0n1' "$CALLS")" "1"
check "blkdiscard ledger"    "$(grep -c 'blkdiscard -f /dev/nvme1n1' "$CALLS")" "1"
check "mkfs accounts"        "$(grep -c 'mkfs.xfs -f /dev/nvme0n1' "$CALLS")"   "1"
check "mkfs ledger"          "$(grep -c 'mkfs.xfs -f /dev/nvme1n1' "$CALLS")"   "1"
check "swapoff issued"       "$(grep -c 'swapoff -a' "$CALLS")"  "1"
check "mount -a issued"      "$(grep -c 'mount -a' "$CALLS")"    "1"
check "fstab ledger entry"   "$(grep -c "U-nvme1n1 $WORK/ledger xfs defaults,noatime,logbufs=8,nofail 0 2" "$FSTAB_FILE")" "1"
check "fstab accounts entry" "$(grep -c "U-nvme0n1 $WORK/accounts xfs " "$FSTAB_FILE")" "1"
check_true "symlink created" "[[ -L \"$SOLANA_LINK\" ]]"
check "ledger_path recorded"   "$(state_get ledger_path)"   "$SOLANA_LINK/ledger"
check "accounts_path recorded" "$(state_get accounts_path)" "$WORK/accounts/solana/accounts"
# I/O isolation: snapshots ride with the LEDGER disk (via /root/solana symlink), never accounts.
check "snapshots on ledger (not accounts)"      "$(state_get snapshots_path)" "$SOLANA_LINK/snapshots"
check_true "snapshots NOT under accounts mount" "[[ \"\$(state_get snapshots_path)\" != \"$ACCOUNTS_MOUNT\"* ]]"
# XFS tuning is applied HERE (Phase 3), after the XFS filesystems are mounted — NOT in Phase 2.
check "XFS drop-in written (22-agave-xfs)"  "$(grep -c 'fs.xfs.xfssyncd_centisecs=10000' "$XFS_SYSCTL_FILE")" "1"
check "xfs modules-load preload written"    "$(grep -cx 'xfs' "$XFS_MODLOAD_FILE")" "1"
check "XFS sysctl applied live (Phase 3)"   "$(grep -c 'sysctl -w fs.xfs.xfssyncd_centisecs=10000' "$CALLS")" "1"

echo "== fstab idempotent (re-run finalize) =="
ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 _disk_finalize_two_nvme >/dev/null 2>&1
check "ledger entry not duplicated"   "$(grep -c "$WORK/ledger xfs" "$FSTAB_FILE")"   "1"
check "accounts entry not duplicated" "$(grep -c "$WORK/accounts xfs" "$FSTAB_FILE")" "1"

echo "== already-mounted -> skip wipe =="
: >"$CALLS"
MP_A="$ACCOUNTS_MOUNT" MP_L="$LEDGER_MOUNT" ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 _disk_two_nvme >/dev/null 2>&1
check "no blkdiscard when already mounted" "$(grep -c blkdiscard "$CALLS")" "0"

echo "== guards: not-root, not-eligible, accounts!=ledger, symlink no-clobber =="
( _disk_assert_not_root /dev/sda sda )      >/dev/null 2>&1; check "refuse wiping root disk"  "$?" "1"
( _disk_assert_not_root /dev/nvme0n1 sda )  >/dev/null 2>&1; check "allow non-root disk"      "$?" "0"
( _disk_assert_eligible /dev/sda sdb )      >/dev/null 2>&1; check "assert_eligible: system refused" "$?" "1"
( _disk_assert_eligible /dev/sdc sdb )      >/dev/null 2>&1; check "assert_eligible: non-NVMe refused" "$?" "1"
( _disk_assert_eligible /dev/nvme0n1 sdb )  >/dev/null 2>&1; check "assert_eligible: NVMe data OK"     "$?" "0"
( ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme0n1 _disk_resolve ) >/dev/null 2>&1
check "refuse accounts==ledger" "$?" "1"
mkdir -p "$WORK/realdir"
( _disk_symlink_home "$WORK/x" "$WORK/realdir" ) >/dev/null 2>&1
check "refuse clobbering real dir" "$?" "1"

echo "== emergency layout (1 NVMe + system, no second NVMe, no RAID0) =="
: >"$CALLS"
LSBLK_ENUM='nvme0n1 2000398934016 disk 0 OnlyOneNVMe
sdb 256060514304 disk 0 BootSSD'
_mp_for() { case "$1" in */sdb) printf '/\n';; *) printf '';; esac; }
findmnt() { echo "/dev/sdb2"; }
export PROC_MDSTAT="$WORK/no_md"            # absent -> no arrays
unset ACCOUNTS_DISK LEDGER_DISK
SOLANA_HOME="$WORK/roothome" disk_run >/dev/null 2>&1
check "layout emergency"             "$(state_get disk_layout)" "emergency"
check "no blkdiscard in emergency"   "$(grep -c blkdiscard "$CALLS")" "0"
check_true "home dirs created"       "[[ -d \"$WORK/roothome/ledger\" && -d \"$WORK/roothome/accounts\" ]]"
check "accounts_path = home/accounts" "$(state_get accounts_path)" "$WORK/roothome/accounts"
unset SOLANA_HOME

echo "== Q2: 2 data NVMe in a RAID0, OS on a separate disk =="
LSBLK_ENUM='sda 256060514304 disk 0 BootSSD
nvme0n1 2000398934016 disk 0 SamsungA
nvme1n1 2000398934016 disk 0 SamsungB'
_mp_for() { case "$1" in */sda) printf '/\n';; *) printf '';; esac; }   # md1 (data) carries nothing
findmnt() { echo "/dev/sda2"; }
export PROC_MDSTAT="$WORK/mdstat_q2"
printf 'Personalities : [raid0]\nmd1 : active raid0 nvme0n1[0] nvme1n1[1]\n      blocks super 1.2\n' >"$PROC_MDSTAT"
_disk_scan_raid
check "Q2 detects data NVMe array"   "$_DISK_DATA_ARRAY" "md1 raid0 nvme0n1 nvme1n1"
# default (non-interactive) choice is 'break'
unset ACCOUNTS_DISK LEDGER_DISK; _DISK_BREAK_ARRAY=""
_disk_resolve >/dev/null 2>&1
check "Q2 break -> two-nvme"          "$DISK_LAYOUT"       "two-nvme"
check "Q2 break flags the array"      "$_DISK_BREAK_ARRAY" "md1"
check "Q2 break accounts on NVMe"     "$ACCOUNTS_DISK"     "/dev/nvme0n1"
# break path actually stops the array before wiping
: >"$CALLS"; MP_A=""; MP_L=""
_disk_two_nvme >/dev/null 2>&1
check "Q2 break stops the array"      "$(grep -c 'mdadm --stop /dev/md1' "$CALLS")" "1"
check "Q2 break then wipes NVMe"      "$(grep -c 'blkdiscard -f /dev/nvme0n1' "$CALLS")" "1"
# 'use' keeps the array as one shared volume
ask_choice() { REPLY=use; }                                       # force the 'use' branch
unset ACCOUNTS_DISK LEDGER_DISK SOLANA_HOME; _DISK_BREAK_ARRAY=""
_disk_resolve >/dev/null 2>&1
check "Q2 use -> raid-volume"         "$DISK_LAYOUT"   "raid-volume"
check "Q2 use volume = md1"           "$_DISK_RAID_MD" "md1"
check "Q2 use home on data mount"     "$SOLANA_HOME"   "$WORK/data/solana"

echo "== set -e safety: detect/resolve/plan must not abort (real-box regression) =="
# Root cause of the live-box crash: a function ending in a `while read ... done`
# loop returns the final read's EOF status (1); called bare under `set -e` (which
# only the real main() sets — these unit tests run WITHOUT -e) it aborted Phase 3
# before the menu. Assert the bare functions return 0, then run the full plan
# under the exact production flags (set -Eeuo pipefail).
LSBLK_ENUM='sda 480103981056 disk 0 INTEL_SSDSC
sdb 480103981056 disk 0 INTEL_SSDSC
nvme0n1 1920383410176 disk 0 Samsung_PM9A3
nvme1n1 1920383410176 disk 0 Samsung_PM9A3'
_mp_for() { case "$1" in */sda) printf '/\n';; */sdb) printf '/boot/efi\n/\n';; */md0) printf '/\n';; *) printf '';; esac; }
findmnt() { echo "/dev/md0"; }
ask_choice() { REPLY="$2"; }                 # non-interactive: take the numbered default
require_yes() { return 0; }
blkid() { return 1; }                        # dry-run reality: NVMe not yet formatted -> blkid finds no UUID
printf 'Personalities : [raid1]\nmd0 : active raid1 sda2[0] sdb2[1]\n      467370048 blocks super 1.2 [2/2] [UU]\n      bitmap: 0/4 pages [0KB], 65536KB chunk\n\nunused devices: <none>\n' >"$PROC_MDSTAT"
_disk_scan_raid; check "_disk_scan_raid returns 0 (not while-read EOF 1)" "$?" "0"
_disk_classify;  check "_disk_classify returns 0"                         "$?" "0"
( set -Eeuo pipefail; unset ACCOUNTS_DISK LEDGER_DISK; DRY_RUN=1 disk_run ) >/dev/null 2>&1
check "full disk_run completes under set -Eeuo pipefail" "$?" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
