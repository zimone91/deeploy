#!/usr/bin/env bash
# Self-contained tests for lib/disk.sh — NO real disks. lsblk/findmnt/blkid/
# mountpoint and every destructive command (blkdiscard/mkfs.xfs/mount/swapoff/
# umount) are mocked; mountpoints/symlink/fstab are temp paths. The headline
# test proves non-interactive (--post-reboot/--yes) NEVER auto-wipes.
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

# Mocks ----------------------------------------------------------------------
LSBLK_LIST='nvme0n1 2000000000000 disk 0 SamsungA
nvme1n1 2000000000000 disk 0 SamsungB
nvme2n1 256000000000 disk 0 BootSSD'
MOUNTED_DEV=""; MP_A=""; MP_L=""
require_root() { :; }                                            # bypass root gate (tested in common)
findmnt() { echo "/dev/nvme2n1p2"; }                              # root on nvme2n1
lsblk() { case "$*" in
    *"NAME,SIZE,TYPE,ROTA,MODEL"*) printf '%s\n' "$LSBLK_LIST" ;;
    *"-b -o SIZE"*)  echo 2000000000000 ;;
    *"-o MODEL"*)    echo "MockNVMe" ;;
    *"-nr -o MOUNTPOINT"*) local d=${!#}; [[ "$d" == "$MOUNTED_DEV" ]] && echo "/inuse" || echo "" ;;
    *) echo "  (device tree)";; esac; }
mountpoint() { local p=${!#}; case "$p" in "$MP_A"|"$MP_L") return 0;; *) return 1;; esac; }
blkid() { local d=${!#}; echo "U-${d##*/}"; }
blkdiscard() { echo "blkdiscard $*" >>"$CALLS"; }
mkfs.xfs()   { echo "mkfs.xfs $*"   >>"$CALLS"; }
mount()      { echo "mount $*"      >>"$CALLS"; }
swapoff()    { echo "swapoff $*"    >>"$CALLS"; }
umount()     { echo "umount $*"     >>"$CALLS"; }
systemctl()  { echo "systemctl $*"  >>"$CALLS"; }

echo "== _disk_base / detection / mapping =="
check "nvme part -> base"  "$(_disk_base /dev/nvme0n1p3)" "nvme0n1"
check "root device"        "$(_disk_root_device)" "nvme2n1"
check "candidates (2, root+small excluded)" "$(_disk_candidates nvme2n1 | wc -l | tr -d ' ')" "2"
unset ACCOUNTS_DISK LEDGER_DISK
_disk_resolve >/dev/null 2>&1
check "layout two-nvme"    "$DISK_LAYOUT" "two-nvme"
check "proposed accounts"  "$ACCOUNTS_DISK" "/dev/nvme0n1"
check "proposed ledger"    "$LEDGER_DISK"   "/dev/nvme1n1"

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
check "blkdiscard accounts" "$(grep -c 'blkdiscard -f /dev/nvme0n1' "$CALLS")" "1"
check "blkdiscard ledger"   "$(grep -c 'blkdiscard -f /dev/nvme1n1' "$CALLS")" "1"
check "mkfs accounts"       "$(grep -c 'mkfs.xfs -f /dev/nvme0n1' "$CALLS")"   "1"
check "mkfs ledger"         "$(grep -c 'mkfs.xfs -f /dev/nvme1n1' "$CALLS")"   "1"
check "swapoff issued"      "$(grep -c 'swapoff -a' "$CALLS")"  "1"
check "mount -a issued"     "$(grep -c 'mount -a' "$CALLS")"    "1"
check "fstab ledger entry"  "$(grep -c "U-nvme1n1 $WORK/ledger xfs defaults,noatime,logbufs=8,nofail 0 2" "$FSTAB_FILE")" "1"
check "fstab accounts entry" "$(grep -c "U-nvme0n1 $WORK/accounts xfs " "$FSTAB_FILE")" "1"
check_true "symlink created" "[[ -L \"$SOLANA_LINK\" ]]"
check "ledger_path recorded"   "$(state_get ledger_path)"   "$SOLANA_LINK/ledger"
check "accounts_path recorded" "$(state_get accounts_path)" "$WORK/accounts/solana/accounts"
# I/O isolation: snapshots ride with the LEDGER disk (via /root/solana symlink), never accounts.
check "snapshots_path on ledger (not accounts)" "$(state_get snapshots_path)" "$SOLANA_LINK/snapshots"
check_true "snapshots NOT under accounts mount"  "[[ \"\$(state_get snapshots_path)\" != \"$ACCOUNTS_MOUNT\"* ]]"

echo "== fstab idempotent (re-run finalize) =="
ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 _disk_finalize_two_nvme >/dev/null 2>&1
check "ledger entry not duplicated"   "$(grep -c "$WORK/ledger xfs" "$FSTAB_FILE")"   "1"
check "accounts entry not duplicated" "$(grep -c "$WORK/accounts xfs" "$FSTAB_FILE")" "1"

echo "== already-mounted -> skip wipe =="
: >"$CALLS"
MP_A="$ACCOUNTS_MOUNT" MP_L="$LEDGER_MOUNT" ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme1n1 _disk_two_nvme >/dev/null 2>&1
check "no blkdiscard when already mounted" "$(grep -c blkdiscard "$CALLS")" "0"

echo "== guards: not-root, accounts!=ledger, symlink no-clobber =="
( _disk_assert_not_root /dev/nvme2n1 nvme2n1 ) >/dev/null 2>&1; check "refuse wiping root disk" "$?" "1"
( _disk_assert_not_root /dev/nvme0n1 nvme2n1 ) >/dev/null 2>&1; check "allow non-root disk"    "$?" "0"
( ACCOUNTS_DISK=/dev/nvme0n1 LEDGER_DISK=/dev/nvme0n1 _disk_resolve ) >/dev/null 2>&1
check "refuse accounts==ledger" "$?" "1"
mkdir -p "$WORK/realdir"
( _disk_symlink_home "$WORK/x" "$WORK/realdir" ) >/dev/null 2>&1
check "refuse clobbering real dir" "$?" "1"

echo "== root layout (single disk / RAID) =="
: >"$CALLS"
LSBLK_LIST='nvme0n1 2000000000000 disk 0 OnlyOne
nvme2n1 256000000000 disk 0 BootSSD'
unset ACCOUNTS_DISK LEDGER_DISK
SOLANA_HOME="$WORK/roothome" disk_run >/dev/null 2>&1
check "layout root"               "$(state_get disk_layout)" "root"
check "no blkdiscard in root layout" "$(grep -c blkdiscard "$CALLS")" "0"
check_true "home dirs created"    "[[ -d \"$WORK/roothome/ledger\" && -d \"$WORK/roothome/accounts\" ]]"
check "accounts_path = home/accounts" "$(state_get accounts_path)" "$WORK/roothome/accounts"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
