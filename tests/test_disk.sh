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
# 'mount -a' mounts what fstab names, by the UUID blkid gave (U-<disk> ->
# /dev/<disk>), into a table findmnt reads back for the sandbox mount points. A
# line it cannot map, or a point in MOUNT_SKIP (nofail and no such device), stays
# a plain directory; MOUNT_ALT="<point>=<device>" mounts a point from elsewhere.
MTAB="$WORK/mtab"; : >"$MTAB"
MOUNT_SKIP=""; MOUNT_ALT=""
mount() {
    echo "mount $*" >>"$CALLS"
    [[ "$*" == "-a" ]] || return 0
    awk '$1 ~ /^UUID=U-/ {d = $1; sub(/^UUID=U-/, "/dev/", d); print $2, d}' "$FSTAB_FILE" |
        while read -r mp d; do
            [[ "$mp" == "$MOUNT_SKIP" ]] && continue
            [[ "$MOUNT_ALT" == "$mp="* ]] && d=${MOUNT_ALT#*=}
            printf '%s %s\n' "$mp" "$d"
        done >"$MTAB"
}
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

# findmnt answers two different questions and the module asks both: the SOURCE of
# / (root backstop) and the TARGET containing the checkout. One dispatching mock,
# driven by knobs, so a scenario cannot answer the wrong one by accident.
FINDMNT_SRC=""              # `findmnt -no SOURCE /`
CK_MOUNT="/"                # `findmnt -no TARGET --target $DEEPLOY_DIR`; "" = unresolvable
# Adoption asks three more questions, each about ONE mount point: is it mounted,
# what device is under it, and what filesystem. Driven by knobs so a scenario
# cannot answer the wrong question by accident, same as the two above. Whether
# DATA_MOUNT is mounted is read from the table 'mount -a' writes, as its device
# is; like findmnt, the answer for a point that is not there is rc 1.
ADOPT_A_SRC=""; ADOPT_L_SRC=""       # "" = that mount point is not mounted
ADOPT_A_FS="xfs"; ADOPT_L_FS="xfs"
FM_CALLS="$WORK/findmnt.calls"; : >"$FM_CALLS"
findmnt() {
    local last=${!#}
    echo "findmnt $*" >>"$FM_CALLS"
    case "$*" in
        *--target*)     [[ -n "$CK_MOUNT" ]] && printf '%s\n' "$CK_MOUNT" ;;
        *"-no TARGET"*) case "$last" in
                            /mnt/accounts) [[ -n "$ADOPT_A_SRC" ]] && printf '%s\n' "$last" ;;
                            /mnt/ledger)   [[ -n "$ADOPT_L_SRC" ]] && printf '%s\n' "$last" ;;
                            "$DATA_MOUNT") awk -v m="$last" '$1 == m {print m; f = 1} END {exit !f}' "$MTAB" ;;
                        esac ;;
        *"-no SOURCE "*|*"-no SOURCE"*)
                        case "$last" in
                            /mnt/accounts) printf '%s\n' "$ADOPT_A_SRC" ;;
                            /mnt/ledger)   printf '%s\n' "$ADOPT_L_SRC" ;;
                            "$WORK"/*)     awk -v m="$last" '$1 == m {print $2; f = 1} END {exit !f}' "$MTAB" ;;
                            *)             printf '%s\n' "$FINDMNT_SRC" ;;
                        esac ;;
        *"-no FSTYPE"*) case "$last" in
                            /mnt/accounts) printf '%s\n' "$ADOPT_A_FS" ;;
                            /mnt/ledger)   printf '%s\n' "$ADOPT_L_FS" ;;
                        esac ;;
        *)              printf '%s\n' "$FINDMNT_SRC" ;;
    esac
}
export DEEPLOY_DIR="$WORK/checkout"; mkdir -p "$DEEPLOY_DIR"

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
FINDMNT_SRC=/dev/md0           # root source IS the array (the buggy case)
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
SWAPFILE="$WORK/none" ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 MP_A="" MP_L="" _disk_two_nvme >/dev/null 2>&1
check "blkdiscard accounts"  "$(grep -c 'blkdiscard -f /dev/nvme0n1' "$CALLS")" "1"
check "blkdiscard ledger"    "$(grep -c 'blkdiscard -f /dev/nvme1n1' "$CALLS")" "1"
check "mkfs accounts"        "$(grep -c 'mkfs.xfs -f /dev/nvme0n1' "$CALLS")"   "1"
check "mkfs ledger"          "$(grep -c 'mkfs.xfs -f /dev/nvme1n1' "$CALLS")"   "1"
check "swapoff issued"       "$(grep -c 'swapoff -a' "$CALLS")"  "1"
check "mount -a issued"      "$(grep -c 'mount -a' "$CALLS")"    "1"
check "fstab ledger entry"   "$(grep -c "U-nvme1n1 $WORK/ledger xfs defaults,noatime,logbufs=8,nofail 0 2" "$FSTAB_FILE")" "1"
check "fstab accounts entry" "$(grep -c "U-nvme0n1 $WORK/accounts xfs " "$FSTAB_FILE")" "1"

echo "== F3: swapfile removal is NON-FATAL (immutable/restricted) under -e =="
SWD="$WORK/swapdir"; mkdir -p "$SWD/keep"          # non-empty dir -> rm -f fails
( set -Eeuo pipefail; SWAPFILE="$SWD" _disk_remove_swapfile ) >/dev/null 2>&1
check "F3: unremovable swapfile -> non-fatal (rc 0 under -e)" "$?" "0"
SWF="$WORK/swapok"; : >"$SWF"                       # a normal, removable swapfile
SWAPFILE="$SWF" _disk_remove_swapfile >/dev/null 2>&1
check "F3: removable swapfile -> deleted"          "$([[ -e "$SWF" ]] && echo y || echo n)" "n"
( set -Eeuo pipefail; SWAPFILE="$WORK/absent-swap" _disk_remove_swapfile ) >/dev/null 2>&1
check "F3: absent swapfile -> no-op (rc 0)"        "$?" "0"
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
# This scenario is a FIRST install, so there may be no record of a data layout: a
# box laid out on data disks refuses to fall back to the system disk, and earlier
# cases in this file leave data_layout=two-nvme behind (and disk_layout, which a
# first install would not have either). require_yes is the file's stub here, as
# if the operator typed 'yes'; section 10 asks for real.
state_clear data_layout; state_clear disk_layout
LSBLK_ENUM='nvme0n1 2000398934016 disk 0 OnlyOneNVMe
sdb 256060514304 disk 0 BootSSD'
_mp_for() { case "$1" in */sdb) printf '/\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/sdb2
export PROC_MDSTAT="$WORK/no_md"            # absent -> no arrays
unset ACCOUNTS_DISK LEDGER_DISK
# In a subshell: a refusal here must fail this check, not end the file. The
# checks below read files (state, CALLS, directories), not variables.
( SOLANA_HOME="$WORK/roothome" disk_run ) >/dev/null 2>&1
check "disk_run rc 0"                "$?" "0"
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
FINDMNT_SRC=/dev/sda2
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
FINDMNT_SRC=/dev/md0           # root source IS the array (the buggy case)
ask_choice() { REPLY="$2"; }                 # non-interactive: take the numbered default
require_yes() { return 0; }
blkid() { return 1; }                        # dry-run reality: NVMe not yet formatted -> blkid finds no UUID
printf 'Personalities : [raid1]\nmd0 : active raid1 sda2[0] sdb2[1]\n      467370048 blocks super 1.2 [2/2] [UU]\n      bitmap: 0/4 pages [0KB], 65536KB chunk\n\nunused devices: <none>\n' >"$PROC_MDSTAT"
# The plan below is a first install: the Q2 case above leaves data_layout=two-nvme,
# and a box with that record and nothing mounted is refused (R10-7c).
state_clear data_layout
_disk_scan_raid; check "_disk_scan_raid returns 0 (not while-read EOF 1)" "$?" "0"
_disk_classify;  check "_disk_classify returns 0"                         "$?" "0"
( set -Eeuo pipefail; unset ACCOUNTS_DISK LEDGER_DISK; DRY_RUN=1 disk_run ) >/dev/null 2>&1
check "full disk_run completes under set -Eeuo pipefail" "$?" "0"

echo "== 7a: NVMe-OS topology — the system-MOUNT filter alone must refuse (X2 feeder) =="
# OS on nvme0n1 (/ + ESP partitions), two CLEAN data NVMe. Every prior negative
# fixture was SATA (/dev/sd*), which the independent NVMe filter already
# rejects — so the system-mount filter itself had ZERO negative coverage on an
# NVMe-OS box (the escaped mutation). Root is passed as 'sda' below so ONLY the
# subtree-has-system check can trip the refusal.
LSBLK_ENUM='nvme0n1 512110190592 disk 0 OS_NVMe
nvme1n1 2000398934016 disk 0 Samsung_PM9A3
nvme2n1 2000398934016 disk 0 Samsung_PM9A3'
_mp_for() { case "$1" in */nvme0n1) printf '/\n/boot/efi\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/nvme0n1p2
export PROC_MDSTAT="$WORK/no_md_7a"    # absent -> no arrays
blkid() { local d=${!#}; echo "U-${d##*/}"; }
ask_choice() { REPLY="$2"; }
_disk_scan_raid; _disk_classify
check "7a: OS NVMe classified as SYSTEM"           "${_DISK_SYSTEM[*]}" "nvme0n1"
check "7a: menu eligible = only the clean NVMe"    "${_DISK_ELIGIBLE[*]}" "nvme1n1 nvme2n1"
( _disk_assert_eligible /dev/nvme0n1 sda ) >/dev/null 2>&1
check "7a: assert_eligible REFUSES the OS NVMe (system-mount filter, not root/NVMe)" "$?" "1"
( _disk_assert_eligible /dev/nvme1n1 sda ) >/dev/null 2>&1
check "7a: a clean NVMe is still accepted"         "$?" "0"
unset ACCOUNTS_DISK LEDGER_DISK
( ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 _disk_resolve ) >/dev/null 2>&1
check "7a: --config path naming the OS NVMe refused end-to-end" "$?" "1"

echo "== 7b: raid-volume destructive path — gate, mkfs argv, mounted-elsewhere =="
_DISK_RAID_MD="md1"; _DISK_RAID_MOUNT="$WORK/data7b"
MP_A=""; MP_L=""
_mp_for() { printf ''; }
# declined (or non-interactive): require_yes blocks BEFORE any mkfs
require_yes() { return 1; }
: >"$CALLS"
( SOLANA_HOME="$WORK/data7b/solana" _disk_raid_volume ) >/dev/null 2>&1
check "7b: declined -> aborts"                "$?" "1"
check "7b: declined -> NO mkfs issued"        "$(grep -c 'mkfs.xfs' "$CALLS")" "0"
# confirmed: mkfs argv targets the md DEVICE, fstab + mount follow
require_yes() { echo "GATE7B" >>"$CALLS"; return 0; }
: >"$CALLS"; : >"$FSTAB_FILE"
SOLANA_HOME="$WORK/data7b/solana" _disk_raid_volume >/dev/null 2>&1
check "7b: gate consulted before mkfs"        "$(grep -c GATE7B "$CALLS")" "1"
check "7b: mkfs argv = the md device"         "$(grep -c 'mkfs.xfs -f /dev/md1' "$CALLS")" "1"
check "7b: mount -a issued"                   "$(grep -c 'mount -a' "$CALLS")" "1"
check "7b: fstab entry for the data mount"    "$(grep -c "UUID=U-md1 $WORK/data7b xfs " "$FSTAB_FILE")" "1"
check_true "7b: home dirs prepared"           "[[ -d \"$WORK/data7b/solana/ledger\" && -d \"$WORK/data7b/solana/accounts\" ]]"
# array mounted somewhere ELSE -> refused, no wipe (manual resolution). It used to
# warn and carry on into the mkdir under the unmounted data mount (R10-7a).
_mp_for() { case "$1" in */md1) printf '/somewhere\n';; *) printf '';; esac; }
: >"$CALLS"; : >"$MTAB"
OUT7B=$( SOLANA_HOME="$WORK/data7b/solana" _disk_raid_volume 2>&1 ); RC7B=$?
check "7b: mounted-elsewhere -> refused"      "$RC7B|$(grep -c 'is mounted at /somewhere — not at' <<<"$OUT7B")" "1|1"
check "7b: mounted-elsewhere -> NO mkfs"      "$(grep -c 'mkfs.xfs' "$CALLS")" "0"

echo "== 7c: the disk holding THIS checkout is never a wipe target =="
# The topology that makes it matter: the checkout is NOT on the system disk. A
# clone onto a spare data NVMe passes every existing filter — not system, is
# NVMe, big enough — and phase 3 would erase the installer mid-run. Same shape as
# the system formula, so md/LVM holders are followed rather than special-cased.
LSBLK_ENUM='sda 256060514304 disk 0 BootSSD
nvme0n1 2000398934016 disk 0 Samsung_PM9A3
nvme1n1 2000398934016 disk 0 Samsung_PM9A3'
_mp_for() { case "$1" in */sda) printf '/\n';; */nvme1n1) printf '/mnt/spare\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/sda2
CK_MOUNT=/mnt/spare                       # the checkout lives on the spare NVMe
export PROC_MDSTAT="$WORK/no_md_7c"       # absent -> no arrays
_disk_scan_raid; _disk_classify
check "7c: checkout disk kept out of eligible"  "${_DISK_ELIGIBLE[*]}" "nvme0n1"
check "7c: and the reason names the checkout" \
      "$(printf '%s\n' "${_DISK_INELIGIBLE[@]}" | grep -c 'holds this DeePloy checkout (/mnt/spare)')" "1"
( _disk_assert_eligible /dev/nvme1n1 sda ) >/dev/null 2>&1
check "7c: assert_eligible REFUSES the checkout disk" "$?" "1"
CKOUT7C=$( ( _disk_assert_eligible /dev/nvme1n1 sda ) 2>&1 || true )
check "7c: the refusal says why"  "$(grep -c 'the install is running from it' <<<"$CKOUT7C")" "1"
# Control, the other way: the OTHER clean NVMe must still be accepted. Without
# this, a check that refused every device would pass the three assertions above.
( _disk_assert_eligible /dev/nvme0n1 sda ) >/dev/null 2>&1
check "7c: a clean NVMe is still accepted"           "$?" "0"

# findmnt is itself an external command, and it is in the set this repo's tool
# gate cannot see. Unresolvable must mean REFUSE, never skip — a skip here widens
# the candidate set at the one moment that is unrecoverable.
CK_MOUNT=""                               # findmnt answers nothing
( _disk_classify ) >/dev/null 2>&1
check "7c: unresolvable checkout -> classify REFUSES"     "$?" "1"
CKOUT7D=$( ( _disk_classify ) 2>&1 || true )
check "7c: and says it will not guess" "$(grep -c 'will not guess' <<<"$CKOUT7D")" "1"
( _disk_assert_eligible /dev/nvme0n1 sda ) >/dev/null 2>&1
check "7c: unresolvable checkout -> assert_eligible REFUSES too" "$?" "1"
# Control: the same call with findmnt answering must NOT refuse — otherwise the
# three above would pass against a function that always died.
CK_MOUNT=/mnt/spare
( _disk_classify ) >/dev/null 2>&1
check "7c: resolvable again -> classify proceeds"         "$?" "0"

# And the missing-tool path, a different branch from an empty answer. Removing the
# mock is NOT how to reach it: on Linux the real findmnt then answers, so that
# version of this control passes only on a box that happens to lack the tool — it
# was written that way first and went red under a PATH carrying a real findmnt.
# Shadow have() instead, so the branch is reached identically on macOS and on the
# ubuntu runner.
no_findmnt() { have() { [[ "$1" != findmnt ]] && command -v "$1" >/dev/null 2>&1; }; }
( no_findmnt; _disk_classify ) >/dev/null 2>&1
check "7c: findmnt absent -> REFUSES (not skipped)"       "$?" "1"
CKOUT7E=$( ( no_findmnt; _disk_classify ) 2>&1 || true )
check "7c: and names the package to install" "$(grep -c 'util-linux' <<<"$CKOUT7E")" "1"
# Control: with have() intact the same call must NOT take that branch.
( _disk_classify ) >/dev/null 2>&1
check "7c: have() intact -> no missing-tool refusal"      "$?" "0"

# The predicate itself must not answer "not carried" for an unresolved mount
# point: that would hand the caller a disk that is merely unidentified. Both call
# sites resolve first, so this is unreachable today — assert it anyway, because
# the comment above it claims construction, not convention.
( _disk_subtree_has_mount nvme1n1 "" ) >/dev/null 2>&1
check "7c: empty mount point -> predicate KILLS the caller"  "$?" "1"
CKOUT7F=$( ( _disk_subtree_has_mount nvme1n1 "" ) 2>&1 || true )
check "7c: and calls it a bug in the module" "$(grep -c 'bug in this module' <<<"$CKOUT7F")" "1"
# Controls both directions, so the assertion above cannot pass against a
# predicate that simply always died.
( _disk_subtree_has_mount nvme1n1 /mnt/spare ) >/dev/null 2>&1
check "7c: resolved + carried    -> 0"                       "$?" "0"
( _disk_subtree_has_mount nvme0n1 /mnt/spare ) >/dev/null 2>&1
check "7c: resolved + not carried -> 1"                      "$?" "1"

echo "== 8: a mounted non-system disk is refused, not unmounted =="
# X2. The wipe path used to print a warning, then umount, then blkdiscard. A
# non-system NVMe carrying /var or /home is exactly the disk an operator does not
# expect to lose, and a warning inside a yes/no prompt is not a gate.
LSBLK_ENUM='nvme0n1 2000398934016 disk 0 Samsung_PM9A3
nvme1n1 2000398934016 disk 0 Samsung_PM9A3'
_mp_for() { case "$1" in
    */nvme0n1) printf '/home\n';;            # somebody's data lives here
    *) printf '';; esac; }
FINDMNT_SRC=/dev/sda ; CK_MOUNT="/"
export PROC_MDSTAT="$WORK/nomd"; : >"$PROC_MDSTAT"

_disk_scan_raid
_disk_classify
check "mounted NVMe is NOT offered"        "$(_disk_in_list nvme0n1 ${_DISK_ELIGIBLE[@]+"${_DISK_ELIGIBLE[@]}"} && echo in || echo out)" "out"
check "  and the reason names the mount"   "$(printf '%s\n' "${_DISK_INELIGIBLE[@]}" | grep -c '^nvme0n1|mounted at /home')" "1"
# Control: the same scenario must still offer the disk that is NOT mounted, or
# the case above would pass on a classifier that offers nothing at all.
check "  while the unmounted sibling IS offered" "$(_disk_in_list nvme1n1 ${_DISK_ELIGIBLE[@]+"${_DISK_ELIGIBLE[@]}"} && echo in || echo out)" "in"

( _disk_assert_eligible /dev/nvme0n1 sda ) >/dev/null 2>&1
check "assert_eligible refuses the mounted one" "$?" "1"
EOUT=$( _disk_assert_eligible /dev/nvme0n1 sda 2>&1 || true )
check "  and says where it is mounted"          "$(grep -c '/home' <<<"$EOUT")" "1"
check "  and says who must unmount it"          "$(grep -c 'Unmount it yourself' <<<"$EOUT")" "1"
( _disk_assert_eligible /dev/nvme1n1 sda ) >/dev/null 2>&1
check "  and still accepts the unmounted one"   "$?" "0"

# --yes is for ordinary confirmations and has never covered disk wipes
# (lib/common.sh:38, :411). This is a fail, not a prompt, so it cannot be
# answered by a flag — asserted rather than assumed.
( ASSUME_YES=1 _disk_assert_eligible /dev/nvme0n1 sda ) >/dev/null 2>&1
check "ASSUME_YES=1 does not buy the mounted disk" "$?" "1"

# The last line of defence, one statement before blkdiscard: it refuses and it
# does NOT unmount. The control is the call log — an automatic umount here would
# disarm both refusals above the moment either is weakened.
: >"$CALLS"
( _disk_assert_not_mounted /dev/nvme0n1 ) >/dev/null 2>&1
check "the pre-wipe guard refuses"          "$?" "1"
check "  and calls no umount"               "$(grep -c '^umount' "$CALLS")" "0"
( _disk_assert_not_mounted /dev/nvme1n1 ) >/dev/null 2>&1
check "  and passes an unmounted disk"      "$?" "0"

echo "== 9: a re-run of a box we already laid out is a different question =="
# The X2 refusal answered "which disk may be erased?" first, and DeePloy's own
# mounted data disks became ineligible — so no layout resolved to two-nvme,
# _disk_two_nvme was never called, its skip-the-wipe branch was unreachable, and
# a working box fell through to the emergency layout, which rewrites the recorded
# paths onto the system disk. Recognition now happens before classification.
adopt_reset() {
    ADOPT_A_SRC=""; ADOPT_L_SRC=""; ADOPT_A_FS="xfs"; ADOPT_L_FS="xfs"
    unset ACCOUNTS_DISK LEDGER_DISK DISK_LAYOUT
    ACCOUNTS_MOUNT=/mnt/accounts; LEDGER_MOUNT=/mnt/ledger
    : >"$CALLS"
    printf 'UUID=AAAA /mnt/accounts xfs defaults,noatime 0 2\nUUID=LLLL /mnt/ledger xfs defaults,noatime 0 2\n' >"$FSTAB_FILE"
}
blkid() { case "${!#}" in */nvme0n1) echo AAAA;; */nvme1n1) echo LLLL;; *) echo XXXX;; esac; }
_disk_symlink_home() { :; }
fstab_for() { awk -v m="$1" '$2==m{print $1}' "$FSTAB_FILE"; }

adopt_reset; ADOPT_A_SRC=/dev/nvme0n1; ADOPT_L_SRC=/dev/nvme1n1
_disk_adopt_existing_layout >/dev/null 2>&1
check "both mounted on our own NVMe -> adopted"   "$?" "0"
check "  accounts taken from its mount point"     "$ACCOUNTS_DISK" "/dev/nvme0n1"
check "  ledger taken from its mount point"       "$LEDGER_DISK"   "/dev/nvme1n1"
check "  layout is two-nvme, not emergency"       "$DISK_LAYOUT"   "two-nvme"
check "  nothing was erased"                      "$(grep -cE 'blkdiscard|mkfs\.xfs' "$CALLS")" "0"
check "  and the menu was never asked"            "$(grep -c 'ask_choice' "$CALLS")" "0"

# The older hazard, and it has nothing to do with X2: a re-run used to ask the
# menu again, and _fstab_ensure keys on the MOUNT POINT, so answering in the
# opposite order replaced each mount's line with the other disk's UUID and the
# two swapped after the reboot. Taking the device FROM the mount point cannot.
adopt_reset; ADOPT_A_SRC=/dev/nvme1n1; ADOPT_L_SRC=/dev/nvme0n1
_disk_adopt_existing_layout >/dev/null 2>&1
check "mounted crosswise -> still adopted"        "$?" "0"
check "  fstab: accounts keeps ITS device"        "$(fstab_for /mnt/accounts)" "UUID=LLLL"
check "  fstab: ledger keeps ITS device"          "$(fstab_for /mnt/ledger)"   "UUID=AAAA"
# Control: the two lines really are different, so the pair above cannot both be
# satisfied by a single value written twice.
check "  control: the two entries differ"         "$([[ "$(fstab_for /mnt/accounts)" != "$(fstab_for /mnt/ledger)" ]] && echo differ || echo same)" "differ"

adopt_reset; ADOPT_A_SRC=/dev/nvme0n1
AOUT=$( _disk_adopt_existing_layout 2>&1 ); ARC=$?
check "only one mounted -> refused"               "$ARC" "1"
check "  and it names which one"                  "$(grep -c '/mnt/accounts is mounted' <<<"$AOUT")" "1"

adopt_reset; ADOPT_A_SRC=/dev/nvme0n1; ADOPT_L_SRC=/dev/nvme1n1; ADOPT_L_FS=ext4
AOUT=$( _disk_adopt_existing_layout 2>&1 ); ARC=$?
check "ledger is not xfs -> refused"              "$ARC" "1"
check "  and it says what it found"               "$(grep -c 'is ext4, not xfs' <<<"$AOUT")" "1"

adopt_reset; ADOPT_A_SRC=/dev/nvme0n1; ADOPT_L_SRC="/dev/sda3[/srv/ledger]"
AOUT=$( _disk_adopt_existing_layout 2>&1 ); ARC=$?
check "a bind mount -> refused"                   "$ARC" "1"
check "  and it says it is not a whole NVMe"      "$(grep -c 'not a whole NVMe disk' <<<"$AOUT")" "1"

adopt_reset; ADOPT_A_SRC=/dev/nvme0n1; ADOPT_L_SRC=/dev/nvme0n1
AOUT=$( _disk_adopt_existing_layout 2>&1 ); ARC=$?
check "both on the same device -> refused"        "$ARC" "1"
check "  and it says they must differ"            "$(grep -c 'must be different physical disks' <<<"$AOUT")" "1"

# Control the other way: a clean first install must be untouched by any of this.
# A first install has no record of a data layout, and the cases above leave
# data_layout=two-nvme. In a subshell: since R10-7c this path can refuse, and a
# refusal must fail these checks, not end the file.
adopt_reset; state_clear data_layout
R9=$( _disk_adopt_existing_layout >/dev/null 2>&1; echo "$?|${DISK_LAYOUT:-unset}" )
check "nothing mounted -> not a re-run, carry on" "${R9%%|*}" "1"
check "  and it set no layout"                    "${R9#*|}" "unset"

echo "== 10 (R10-7b): the system volume takes the ledger only after a typed yes, and never on a box laid out on data disks =="
# Both paths onto the system volume — the emergency layout, and a RAID0 array
# that carries / — write no filesystem, but _disk_record_paths repoints
# solana_home, ledger_path, snapshots_path and accounts_path at /root/solana. On
# a box laid out on data disks the real ledger would be left unreferenced, so
# that refuses; anywhere else the operator's own typed 'yes' decides. The record
# of "laid out" is data_layout, written by the data layouts after the mount
# check; disk_layout is recorded before the wipe question and is not it. The
# questions here go through the real require_yes, not the file's stub.
eval "$(sed -n '/^require_yes() {/,/^}/p' "$ROOT/lib/common.sh")"
adopt_reset
LSBLK_ENUM='sda 256060514304 disk 0 SATA_ONLY'
_mp_for() { case "$1" in */sda) printf '/\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/sda; CK_MOUNT="/"
export PROC_MDSTAT="$WORK/nomd_e"; : >"$PROC_MDSTAT"
S10_BEFORE="/before|/before/accounts|<none>"
s10_reset() {
    local k; for k in data_layout disk_layout phase-3; do state_clear "$k"; done
    state_set solana_home /before; state_set accounts_path /before/accounts
    : >"$CALLS"; unset SOLANA_HOME DISK_LAYOUT
}
s10_state() { printf '%s|%s|%s' "$(state_get solana_home)" "$(state_get accounts_path)" "$(state_get disk_layout '<none>')"; }
ASKED="Type 'yes'|without explicit confirmation"

s10_reset; state_set data_layout two-nvme
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: laid out as two-nvme, no data disk now -> refused"    "$ERC|$(grep -c 'laid out on data disks (two-nvme)' <<<"$EOUT")" "1|1"
check "  and nothing asked, nothing changed [two-nvme]"             "$(grep -cE "$ASKED" <<<"$EOUT")|$(s10_state)" "0|$S10_BEFORE"
check "  and it names how a deliberate re-layout clears the record" "$(grep -c "echo none > $DEEPLOY_STATE_DIR/state.d/data_layout" <<<"$EOUT")" "1"
s10_reset; state_set data_layout raid-volume
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: laid out as raid-volume -> refused"                  "$ERC|$(grep -c 'laid out on data disks (raid-volume)' <<<"$EOUT")|$(s10_state)" "1|1|$S10_BEFORE"
# A box laid out before data_layout existed: phase 3 done, accounts on a data mount.
s10_reset; state_set phase-3 x; state_set accounts_path /mnt/accounts/solana/accounts
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: rc9 box, accounts under /mnt/accounts -> refused as two-nvme" "$ERC|$(grep -c 'laid out on data disks (two-nvme)' <<<"$EOUT")" "1|1"
s10_reset; state_set phase-3 x; state_set accounts_path "$DATA_MOUNT/solana/accounts"
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: rc9 box, accounts under the data mount -> refused as raid-volume" "$ERC|$(grep -c 'laid out on data disks (raid-volume)' <<<"$EOUT")" "1|1"
# Not laid out: the question decides. Without a tty (as here) it refuses.
s10_reset; state_set phase-3 x; state_set accounts_path /root/solana/accounts
EOUT=$( disk_run 2>&1 ); ERC=$?
check "R10-7b: an emergency box (phase 3 done, accounts on /root/solana) -> asked, no tty -> refused" "$ERC|$(grep -c 'without explicit confirmation' <<<"$EOUT")|$(grep -c 'Declined (or no terminal to ask on): nothing was changed' <<<"$EOUT")" "1|1|1"
check "  and nothing changed, no swapoff [no tty]"                  "$(grep -c swapoff "$CALLS")|$(s10_state)" "0|/before|/root/solana/accounts|<none>"
s10_reset; state_set accounts_path /mnt/accounts/solana/accounts
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: accounts path without phase 3 (an import) is no record -> asked" "$ERC|$(grep -c 'without explicit confirmation' <<<"$EOUT")|$(grep -c 'laid out on data disks' <<<"$EOUT")" "1|1|0"
s10_reset; state_set phase-3 x; state_set accounts_path /mnt/accounts/solana/accounts; state_set data_layout none
EOUT=$( printf 'yes\n' | { NONINTERACTIVE=0; _disk_resolve; } 2>&1 ); ERC=$?
check "R10-7b: record cleared (data_layout=none) -> asked, yes -> emergency" "$ERC|$(state_get disk_layout '<none>')" "0|emergency"
# DISK-STATE-BEFORE-GATE: disk_layout is written before the wipe question, so a
# declined wipe leaves two-nvme behind. That is no record of a data layout.
s10_reset; state_set disk_layout two-nvme
EOUT=$( printf 'yes\n' | { NONINTERACTIVE=0; _disk_resolve; } 2>&1 ); ERC=$?
check "R10-7b: disk_layout=two-nvme from a declined wipe -> asked, yes -> emergency" "$ERC|$(grep -c 'laid out' <<<"$EOUT")|$(state_get disk_layout)" "0|0|emergency"
s10_reset
EOUT=$( printf 'no\n' | { NONINTERACTIVE=0; disk_run; } 2>&1 ); ERC=$?
check "R10-7b: first install, the question is asked"                "$(grep -c 'Put the ledger, accounts and snapshots on the system disk?' <<<"$EOUT")|$(grep -c "Type 'yes' to proceed" <<<"$EOUT")" "1|1"
check "  answer no -> refused, nothing changed, no swapoff"          "$ERC|$(grep -c swapoff "$CALLS")|$(s10_state)" "1|0|$S10_BEFORE"
s10_reset
EOUT=$( printf 'y\n' | { NONINTERACTIVE=0; _disk_resolve; } 2>&1 ); ERC=$?
check "R10-7b: answer y (not yes) -> refused, nothing changed"       "$ERC|$(s10_state)" "1|$S10_BEFORE"
s10_reset
EOUT=$( ASSUME_YES=1 _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: --yes does not answer it (no tty) -> refused"        "$ERC|$(s10_state)" "1|$S10_BEFORE"
s10_reset
EOUT=$( printf 'yes\n' | { NONINTERACTIVE=0; _disk_resolve; } 2>&1 ); ERC=$?
check "R10-7b: answer yes -> emergency, on /root/solana"            "$ERC|$(state_get disk_layout)|$(grep -c '(/root/solana) with the OS' <<<"$EOUT")" "0|emergency|1"
check "  and it said why there was no other volume"                 "$(grep -c 'No eligible NVMe' <<<"$EOUT")" "1"
# The other path onto the system volume: a RAID0 array that carries / itself.
# It used to be taken without a word (the rc8 notes' correction).
LSBLK_ENUM='sda 480103981056 disk 0 SATA_A
sdb 480103981056 disk 0 SATA_B'
_mp_for() { case "$1" in */sda|*/sdb|*/md0) printf '/\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/md0
export PROC_MDSTAT="$WORK/md_sys0"
printf 'Personalities : [raid0]\nmd0 : active raid0 sdb2[1] sda2[0]\n      937438976 blocks super 1.2 512k chunks\n' >"$PROC_MDSTAT"
s10_reset
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: system RAID0, no tty -> asked, refused, nothing changed" "$ERC|$(grep -c 'without explicit confirmation' <<<"$EOUT")|$(s10_state)" "1|1|$S10_BEFORE"
s10_reset
EOUT=$( printf 'yes\n' | { NONINTERACTIVE=0; _disk_resolve; } 2>&1 ); ERC=$?
check "R10-7b: system RAID0, the question names the array"         "$(grep -c 'Put the ledger, accounts and snapshots on /dev/md0, the RAID0 array that also carries /?' <<<"$EOUT")" "1"
check "  answer yes -> raid-volume on /root/solana"                 "$ERC|$(state_get disk_layout)|$(grep -c '(/root/solana) with the OS' <<<"$EOUT")" "0|raid-volume|1"
s10_reset; state_set data_layout two-nvme
EOUT=$( _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: system RAID0 on a box laid out as two-nvme -> refused, nothing asked" "$ERC|$(grep -c 'laid out on data disks (two-nvme)' <<<"$EOUT")|$(grep -cE "$ASKED" <<<"$EOUT")|$(s10_state)" "1|1|0|$S10_BEFORE"
# The probe runs inside $( ): under the production traps the refusal comes out alone.
s10_reset; state_set phase-3 x; state_set accounts_path /mnt/accounts/solana/accounts
EOUT=$( set -Eeuo pipefail; deeploy_init_traps; _disk_resolve 2>&1 ); ERC=$?
check "R10-7b: under the production traps the refusal comes out alone" "$ERC|$(grep -cE 'line [0-9]+:' <<<"$EOUT")|$(grep -c 'laid out on data disks' <<<"$EOUT")" "1|0|1"
s10_reset

echo "== R10-7a: data directories are created only on the mounted data filesystems =="
# An empty UUID from blkid wrote no fstab line, 'mount -a' left the point a plain
# directory on /, and the data directories and their recorded paths went to the
# root filesystem, where agave would put its ledger. Now an empty UUID refuses,
# and each point must be mounted from its own device before anything is created
# under it. The same holds for a data RAID volume.
blkid() { local d=${!#}; [[ "$d" == "$BLKID_EMPTY" ]] && return 2; echo "U-${d##*/}"; }
require_yes() { return 0; }
r7a_reset() {
    LEDGER_MOUNT="$WORK/r7a/ledger"; ACCOUNTS_MOUNT="$WORK/r7a/accounts"
    ACCOUNTS_DISK=/dev/nvme0n1; LEDGER_DISK=/dev/nvme1n1
    _DISK_RAID_MD=md1; _DISK_RAID_MOUNT="$WORK/r7a/data"; SOLANA_HOME="$WORK/r7a/data/solana"
    _mp_for() { printf ''; }
    BLKID_EMPTY=""; MOUNT_SKIP=""; MOUNT_ALT=""; MP_A=""; MP_L=""
    rm -rf "$WORK/r7a"; mkdir -p "$WORK/r7a"
    : >"$FSTAB_FILE"; : >"$MTAB"; : >"$CALLS"; : >"$FM_CALLS"
    state_set ledger_path untouched; state_set accounts_path untouched
}
# What a refusal leaves: nothing below the mount points, and no recorded paths.
r7a_nothing() {
    printf '%s|%s|%s' "$(find "$WORK/r7a" -mindepth 2 2>/dev/null | wc -l | tr -d ' ')" \
        "$(state_get ledger_path)" "$(state_get accounts_path)"
}

r7a_reset; BLKID_EMPTY=/dev/nvme1n1
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: no UUID on the ledger disk -> refused"             "$RC|$(grep -c "no filesystem UUID on /dev/nvme1n1, so no fstab line can be written for $LEDGER_MOUNT," <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [ledger, no UUID]" "$(r7a_nothing)" "0|untouched|untouched"
check "  and no fstab line written, no mount -a"                  "$(wc -l <"$FSTAB_FILE" | tr -d ' ')|$(grep -c 'mount -a' "$CALLS")" "0|0"
r7a_reset; BLKID_EMPTY=/dev/nvme0n1
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: no UUID on the accounts disk -> refused"           "$RC|$(grep -c "no filesystem UUID on /dev/nvme0n1, so no fstab line can be written for $ACCOUNTS_MOUNT," <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [accounts, no UUID]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; MOUNT_SKIP="$LEDGER_MOUNT"
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: mount -a left the ledger point unmounted -> refused"   "$RC|$(grep -c "$LEDGER_MOUNT is not mounted after 'mount -a'" <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [ledger unmounted]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; MOUNT_SKIP="$ACCOUNTS_MOUNT"
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: mount -a left the accounts point unmounted -> refused" "$RC|$(grep -c "$ACCOUNTS_MOUNT is not mounted after 'mount -a'" <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [accounts unmounted]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; MOUNT_ALT="$LEDGER_MOUNT=/dev/sdz"
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: ledger point mounted from another device -> refused"   "$RC|$(grep -c "$LEDGER_MOUNT is mounted from /dev/sdz, not from /dev/nvme1n1" <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [ledger elsewhere]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; MOUNT_ALT="$LEDGER_MOUNT=/dev/nvme1n1p1"
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: ledger point mounted from a partition of its disk -> refused" "$RC|$(grep -c "$LEDGER_MOUNT is mounted from /dev/nvme1n1p1, not from /dev/nvme1n1\." <<<"$OUT")" "1|1"
r7a_reset; MOUNT_ALT="$ACCOUNTS_MOUNT=/dev/sdz"
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: accounts point mounted from another device -> refused" "$RC|$(grep -c "$ACCOUNTS_MOUNT is mounted from /dev/sdz, not from /dev/nvme0n1" <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [accounts elsewhere]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset
OUT=$( _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: control: both mounted from their own disks -> done"    "$RC" "0"
check "  and the data directories are on them, the paths recorded"    "$([[ -d $LEDGER_MOUNT/solana && -d $ACCOUNTS_MOUNT/solana ]] && echo y)|$(state_get accounts_path)" "y|$ACCOUNTS_MOUNT/solana/accounts"
check "  and findmnt was asked about one mount point per call"        "$(grep -c -- '-no SOURCE' "$FM_CALLS")|$(awk '/-no SOURCE/ && NF != 4' "$FM_CALLS" | wc -l | tr -d ' ')" "2|0"
# A dry-run never ran mkfs, so blkid may have nothing yet: it says what the real
# run checks instead of refusing, and plans no fstab line without a UUID.
r7a_reset; BLKID_EMPTY=/dev/nvme1n1
OUT=$( DRY_RUN=1 _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: dry-run with no UUID yet -> carries on"            "$RC" "0"
check "  and says what the real run checks"                       "$(grep -c '/dev/nvme1n1 has no filesystem UUID yet' <<<"$OUT")|$(grep -c "would check that $LEDGER_MOUNT is mounted from /dev/nvme1n1" <<<"$OUT")|$(grep -c "would check that $ACCOUNTS_MOUNT is mounted from /dev/nvme0n1" <<<"$OUT")" "1|1|1"
check "  and plans the fstab line for the accounts disk only"     "$(grep -c "would update $FSTAB_FILE" <<<"$OUT")" "1"
# The probe sits inside an assignment, where a non-zero status wakes DeePloy's
# ERR trap; the refusal must come out alone, with no stray "[FAIL] line N".
r7a_reset; MOUNT_SKIP="$LEDGER_MOUNT"
OUT=$( set -Eeuo pipefail; deeploy_init_traps; _disk_finalize_two_nvme 2>&1 ); RC=$?
check "R10-7a: under the production traps the refusal comes out alone" "$RC|$(grep -cE 'line [0-9]+:' <<<"$OUT")|$(grep -c 'is not mounted after' <<<"$OUT")" "1|0|1"

# A data RAID volume (_disk_mount_data_array, through _disk_raid_volume).
r7a_reset; BLKID_EMPTY=/dev/md1
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: data RAID, no UUID after mkfs -> refused"          "$RC|$(grep -c "no filesystem UUID on /dev/md1, so no fstab line can be written for $_DISK_RAID_MOUNT," <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [data RAID, no UUID]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; MOUNT_SKIP="$_DISK_RAID_MOUNT"
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: data RAID not mounted after mount -a -> refused"   "$RC|$(grep -c "$_DISK_RAID_MOUNT is not mounted after 'mount -a'" <<<"$OUT")" "1|1"
check "  and nothing created, no paths recorded [data RAID unmounted]" "$(r7a_nothing)" "0|untouched|untouched"
r7a_reset; _mp_for() { case "$1" in */md1) printf '/srv/data\n';; *) printf '';; esac; }
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: data RAID mounted elsewhere -> refused"            "$RC|$(grep -c "/dev/md1 is mounted at /srv/data — not at $_DISK_RAID_MOUNT," <<<"$OUT")" "1|1"
check "  and no mkfs, nothing created, no paths recorded [data RAID mounted elsewhere]" "$(grep -c mkfs.xfs "$CALLS")|$(r7a_nothing)" "0|0|untouched|untouched"
r7a_reset; printf '%s /dev/sdz\n' "$_DISK_RAID_MOUNT" >"$MTAB"; MP_A="$_DISK_RAID_MOUNT"
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: data mount already taken by another device -> refused" "$RC|$(grep -c "$_DISK_RAID_MOUNT is already mounted from /dev/sdz, not from /dev/md1" <<<"$OUT")" "1|1"
check "  and no mkfs, nothing created, no paths recorded [data mount taken]" "$(grep -c mkfs.xfs "$CALLS")|$(r7a_nothing)" "0|0|untouched|untouched"
r7a_reset; printf '%s /dev/md1\n' "$_DISK_RAID_MOUNT" >"$MTAB"; MP_A="$_DISK_RAID_MOUNT"
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: control: data RAID already at its point -> used, no mkfs" "$RC|$(grep -c mkfs.xfs "$CALLS")|$(state_get accounts_path)" "0|0|$SOLANA_HOME/accounts"
r7a_reset
OUT=$( _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: control: data RAID formatted and mounted -> paths recorded" "$RC|$(grep -c mkfs.xfs "$CALLS")|$(state_get accounts_path)" "0|1|$SOLANA_HOME/accounts"
# The first probe asks about a point that is not mounted yet: under the
# production traps that must stay quiet too.
r7a_reset
OUT=$( set -Eeuo pipefail; deeploy_init_traps; _disk_raid_volume 2>&1 ); RC=$?
check "R10-7a: data RAID under the production traps -> done, no stray [FAIL] line" "$RC|$(grep -cE 'line [0-9]+:' <<<"$OUT")" "0|0"

echo "== R10-7b: data_layout is written only by a data layout, after its mount check =="
r7a_reset; state_clear data_layout
( _disk_finalize_two_nvme ) >/dev/null 2>&1
check "R10-7b: a two-nvme layout records data_layout=two-nvme"     "$(state_get data_layout '<none>')" "two-nvme"
r7a_reset; state_clear data_layout; MOUNT_SKIP="$LEDGER_MOUNT"
( _disk_finalize_two_nvme ) >/dev/null 2>&1
check "  a refused mount check records nothing"                     "$(state_get data_layout '<none>')" "<none>"
r7a_reset; state_clear data_layout
( _disk_raid_volume ) >/dev/null 2>&1
check "R10-7b: a data RAID volume records data_layout=raid-volume" "$(state_get data_layout '<none>')" "raid-volume"
r7a_reset; state_clear data_layout; MOUNT_SKIP="$_DISK_RAID_MOUNT"
( _disk_raid_volume ) >/dev/null 2>&1
check "  a data RAID volume that did not mount records nothing"    "$(state_get data_layout '<none>')" "<none>"
r7a_reset; state_clear data_layout; _DISK_RAID_MOUNT=""; SOLANA_HOME="$WORK/r7a/sys/solana"
( _disk_raid_volume ) >/dev/null 2>&1
check "  the array that carries / records nothing"                  "$(state_get data_layout '<none>')|$(state_get accounts_path)" "<none>|$WORK/r7a/sys/solana/accounts"
r7a_reset; state_clear data_layout
( SOLANA_HOME="$WORK/r7a/emerg" _disk_emergency_layout ) >/dev/null 2>&1
check "  the emergency layout records nothing"                      "$(state_get data_layout '<none>')|$(state_get accounts_path)" "<none>|$WORK/r7a/emerg/accounts"

echo "== R10-7c: laid out on data disks, nothing mounted: not a first install =="
# Nothing mounted at the data points read as a first install: the disk menu, or
# the break/use question for a data RAID, then the question to erase. On a box
# laid out on data disks whose data did not mount, the disks offered can be the
# ones that hold its ledger. Now the record answers first. Each question is
# recorded here; the erase is declined, so a run that gets that far changes no
# disk, but it has already recorded disk_layout and the disks.
adopt_reset
LSBLK_ENUM='sda 256060514304 disk 0 BootSSD
nvme0n1 2000398934016 disk 0 SamsungA
nvme1n1 2000398934016 disk 0 SamsungB'
_mp_for() { case "$1" in */sda) printf '/\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/sda2; CK_MOUNT="/"
export PROC_MDSTAT="$WORK/md_r7c" SWAPFILE="$WORK/no-swapfile"
ask_choice()  { echo "ASKED $1" >>"$CALLS"; REPLY=${R7C_PICK:-$2}; }
require_yes() { echo "ASKED $1" >>"$CALLS"; return 1; }
R7C_MD1='Personalities : [raid0]\nmd1 : active raid0 nvme0n1[0] nvme1n1[1]\n      blocks super 1.2\n'
r7c_reset() {
    adopt_reset; R7C_PICK=""; : >"$MTAB"; : >"$PROC_MDSTAT"; unset SOLANA_HOME
    local k; for k in data_layout disk_layout accounts_disk ledger_disk phase-3 accounts_path; do state_clear "$k"; done
}
# questions asked | swapoff, erase or mdadm run | disk_layout recorded
r7c_left() {
    printf '%s|%s|%s' "$(grep -c '^ASKED' "$CALLS")" "$(grep -cE '^(swapoff|blkdiscard|mkfs\.xfs|mdadm)' "$CALLS")" \
        "$(state_get disk_layout '<none>')"
}

r7c_reset; state_set data_layout two-nvme
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: laid out as two-nvme, neither point mounted -> refused" "$RC|$(grep -c 'laid out on data disks (two-nvme), and neither /mnt/accounts nor /mnt/ledger is mounted' <<<"$OUT")|$(grep -c "Mount them (their lines are in $FSTAB_FILE), then run again." <<<"$OUT")" "1|1|1"
check "  before any question: nothing asked, run or recorded [two-nvme]" "$(r7c_left)" "0|0|<none>"
check "  and it names the action that clears the record [two-nvme]"   "$(grep -c "echo none > $DEEPLOY_STATE_DIR/state.d/data_layout" <<<"$OUT")" "1"
# A box laid out by rc9 or older: no data_layout, the record is phase 3 and the path.
r7c_reset; state_set phase-3 x; state_set accounts_path /mnt/accounts/solana/accounts
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: rc9 box, accounts under /mnt/accounts, nothing mounted -> refused as two-nvme" "$RC|$(grep -c 'laid out on data disks (two-nvme)' <<<"$OUT")|$(r7c_left)" "1|1|0|0|<none>"
# A data RAID volume whose mount is missing: the array is still assembled, so a
# first install would ask break/use, and both answers erase it.
r7c_reset; state_set data_layout raid-volume; printf '%b' "$R7C_MD1" >"$PROC_MDSTAT"
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: laid out as raid-volume, the data mount not mounted -> refused" "$RC|$(grep -c "laid out on data disks (raid-volume), and $DATA_MOUNT is not mounted" <<<"$OUT")|$(grep -c "Mount it (its line is in $FSTAB_FILE), then run again." <<<"$OUT")" "1|1|1"
check "  before the break/use question: nothing asked, run or recorded [raid-volume]" "$(r7c_left)" "0|0|<none>"
# Control: mounted from its array, the volume is used again and nothing is erased.
r7c_reset; state_set data_layout raid-volume; printf '%b' "$R7C_MD1" >"$PROC_MDSTAT"
printf '%s /dev/md1\n' "$DATA_MOUNT" >"$MTAB"; R7C_PICK=use
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: control: raid-volume with its data mounted -> goes on, used, nothing erased" "$RC|$(grep -c 'laid out on data disks' <<<"$OUT")|$(grep -cE '^(blkdiscard|mkfs\.xfs)' "$CALLS")|$(state_get accounts_path)" "0|0|0|$DATA_MOUNT/solana/accounts"
# Control: "none" clears the record, the rc9 fallback included -> a first install.
r7c_reset; state_set phase-3 x; state_set accounts_path /mnt/accounts/solana/accounts; state_set data_layout none
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: control: record cleared (none) -> the menu, then the erase question" "$(grep -c '^ASKED Select ACCOUNTS disk' "$CALLS")|$(grep -c '^ASKED PERMANENTLY ERASE' "$CALLS")|$(grep -c 'laid out on data disks' <<<"$OUT")" "1|1|0"
# Control: a declined erase is no layout. disk_layout is recorded before the
# question (the false refusal R10-7b removed), and the run after it is a first
# install again: the menu and the erase question come back, and nothing refuses.
r7c_reset
( disk_run ) >/dev/null 2>&1
R7C_PRE="$(state_get disk_layout '<none>')|$(state_get data_layout '<none>')"; : >"$CALLS"
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: control: erase declined, then run again -> a first install again" "$R7C_PRE|$(grep -c '^ASKED Select ACCOUNTS disk' "$CALLS")|$(grep -c '^ASKED PERMANENTLY ERASE' "$CALLS")|$(grep -c 'laid out on data disks' <<<"$OUT")" "two-nvme|<none>|1|1|0"
r7c_reset; state_set data_layout three-nvme
OUT=$( disk_run 2>&1 ); RC=$?
check "R10-7c: a layout this version does not know -> refused, nothing asked" "$RC|$(grep -c 'laid out on data disks (three-nvme), and this version does not know that layout' <<<"$OUT")|$(r7c_left)" "1|1|0|0|<none>"
r7c_reset; state_set data_layout two-nvme
OUT=$( DRY_RUN=1 disk_run 2>&1 ); RC=$?
check "R10-7c: a dry-run refuses the same way, before any question"  "$RC|$(grep -c 'laid out on data disks (two-nvme)' <<<"$OUT")|$(r7c_left)" "1|1|0|0|<none>"
# Whether a point is mounted is asked inside $( ), and findmnt answers rc 1 for a
# point that is not. Under the production traps on bash 3.2 that printed a stray
# [FAIL] line for each probe, adopt's two included. The refusal comes out alone.
r7c_reset; state_set data_layout raid-volume
OUT=$( set -Eeuo pipefail; deeploy_init_traps; disk_run 2>&1 ); RC=$?
check "R10-7c: under the production traps the refusal comes out alone" "$RC|$(grep -cE 'line [0-9]+:' <<<"$OUT")|$(grep -c 'laid out on data disks' <<<"$OUT")" "1|0|1"
r7c_reset

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
