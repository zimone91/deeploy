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

# findmnt answers two different questions and the module asks both: the SOURCE of
# / (root backstop) and the TARGET containing the checkout. One dispatching mock,
# driven by knobs, so a scenario cannot answer the wrong one by accident.
FINDMNT_SRC=""              # `findmnt -no SOURCE /`
CK_MOUNT="/"                # `findmnt -no TARGET --target $DEEPLOY_DIR`; "" = unresolvable
findmnt() {
    case "$*" in
        *--target*) [[ -n "$CK_MOUNT" ]] && printf '%s\n' "$CK_MOUNT" ;;
        *)          printf '%s\n' "$FINDMNT_SRC" ;;
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
LSBLK_ENUM='nvme0n1 2000398934016 disk 0 OnlyOneNVMe
sdb 256060514304 disk 0 BootSSD'
_mp_for() { case "$1" in */sdb) printf '/\n';; *) printf '';; esac; }
FINDMNT_SRC=/dev/sdb2
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
# array mounted somewhere ELSE -> warn + no wipe (manual resolution)
_mp_for() { case "$1" in */md1) printf '/somewhere\n';; *) printf '';; esac; }
: >"$CALLS"
OUT7B=$( SOLANA_HOME="$WORK/data7b/solana" _disk_raid_volume 2>&1 )
check "7b: mounted-elsewhere -> warns"        "$(grep -c 'mounted elsewhere' <<<"$OUT7B")" "1"
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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
