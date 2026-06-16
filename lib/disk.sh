#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/disk.sh   (Phase 3: storage)
# Detect disks -> classify (system / eligible NVMe / shown-but-not-selectable)
# -> propose accounts/ledger mapping -> confirm -> (only then) blkdiscard +
# mkfs.xfs + mount + fstab + symlink. This is the most destructive phase, so
# DISK SELECTION is doubly safe:
#
#   SYSTEM-DISK EXCLUSION (by mount, RAID/LVM-aware): a physical disk is a
#   SYSTEM disk if anything in its block subtree carries /, /boot, /boot/efi or
#   swap — INCLUDING through an md/LVM holder. So when / lives on md0 built from
#   sda2+sdb2, BOTH sda and sdb are tagged system and excluded. One unified
#   formula, no special-casing RAID0/RAID1/single. (This replaces the old
#   base-name match, which turned /dev/md0 into the string "md" and let the real
#   members sda/sdb slip through as data candidates.)
#
#   NVMe-ONLY ELIGIBILITY: accounts/ledger candidates must be NVMe — SATA/SAS
#   random-I/O can't sustain a mainnet validator. Non-NVMe disks are shown in
#   the table for transparency but are NOT selectable. Two INDEPENDENT filters
#   (system-mount AND device-type) so a system disk can't slip through even if
#   RAID detection missed it.
#
#   NUMBERED MENU (no free-path entry): the operator picks accounts/ledger from
#   a numbered list of eligible NVMe — system and non-NVMe disks are not in the
#   selectable set, so they can't be typed in. _disk_assert_eligible re-checks
#   not-root + not-system + NVMe as a backstop even for --config-provided paths.
#
# Placement priority:
#   1. >= 2 eligible NVMe          -> two-nvme   (accounts/ledger on separate NVMe)
#   2. < 2 NVMe but a RAID0 exists -> raid-volume (use the EXISTING array as one
#                                     volume; never create one). Path: /root/solana
#                                     if it carries /, else /mnt/data/solana.
#   3. otherwise                   -> emergency  (everything on the system disk;
#                                     LOUD "not recommended for mainnet" warning)
#   Q2: if the 2 data NVMe are themselves joined in a RAID and the OS is on a
#       separate disk -> prompt break-into-2 / use-as-one / cancel.
#
# Requires: common.sh sourced. lsblk/findmnt/blkid/mountpoint/mdadm are
# read-only probes here (mockable); all mutations go through run(); fstab path
# is overridable (FSTAB_FILE) for tests.
# ============================================================================

[[ -n "${_DEEPLOY_DISK_SOURCED:-}" ]] && return 0
_DEEPLOY_DISK_SOURCED=1

DISK_MIN_GB="${DISK_MIN_GB:-400}"                 # data-disk candidate size floor
LEDGER_MOUNT="${LEDGER_MOUNT:-/mnt/ledger}"
ACCOUNTS_MOUNT="${ACCOUNTS_MOUNT:-/mnt/accounts}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"             # single-volume data-RAID mount
SOLANA_LINK="${SOLANA_LINK:-/root/solana}"        # symlink -> <ledger>/solana (overridable for tests)
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
XFS_MOUNT_OPTS="defaults,noatime,logbufs=8,nofail"
XFS_SYSCTL_FILE="${XFS_SYSCTL_FILE:-/etc/sysctl.d/22-agave-xfs.conf}"
XFS_SYNCD_CENTISECS="${XFS_SYNCD_CENTISECS:-10000}"   # default 3000 -> 10000: less accountsdb overhead
XFS_MODLOAD_FILE="${XFS_MODLOAD_FILE:-/etc/modules-load.d/deeploy-xfs.conf}"

# Classification buckets (module globals, filled by _disk_classify/_disk_scan_raid).
_DISK_ELIGIBLE=()             # eligible NVMe candidate disk names (selectable)
_DISK_SYSTEM=()               # system disk names (excluded, shown)
_DISK_INELIGIBLE=()           # "name|reason" — shown but NOT selectable
_DISK_DATA_ARRAY=""           # "md level m1 m2..." a non-system all-NVMe md array (Q2)
_DISK_DATA_ARRAY_MEMBERS=()   # base disks that are members of non-system arrays
_DISK_RAID0_VOL=""            # "md sysflag" first raid0 volume found
_DISK_BREAK_ARRAY=""          # set to an md name when the operator chose to break it
_DISK_RAID_MD=""              # the array backing a raid-volume layout
_DISK_RAID_MOUNT=""           # where to mount a data raid-volume (empty when it IS /)

# --- low-level detection (read-only; mockable) -------------------------------
_disk_base() {                                    # nvme0n1p2 -> nvme0n1 ; sda2 -> sda
    local s=${1##*/}
    if   [[ "$s" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^([a-z]+)[0-9]+$ ]];             then printf '%s' "${BASH_REMATCH[1]}"
    else printf '%s' "$s"; fi
}
_disk_root_device() { _disk_base "$(findmnt -no SOURCE / 2>/dev/null)"; }   # simple-case not-root backstop
_disk_size_bytes()  { lsblk -dn -b -o SIZE "$1" 2>/dev/null | head -1; }
_disk_model()       { lsblk -dn -o MODEL "$1" 2>/dev/null | head -1; }
_disk_human()       { awk -v b="${1:-0}" 'BEGIN{ if (b>=1000000000000) printf "%.2f TB", b/1000000000000; else printf "%.0f GB", b/1000000000 }'; }
_disk_is_nvme()     { case "${1##*/}" in nvme*) return 0;; *) return 1;; esac; }
_disk_mounted_anywhere() { [[ -n "$(lsblk -nr -o MOUNTPOINT "$1" 2>/dev/null | awk 'NF{print; exit}')" ]]; }
_disk_in_list()     { local x=$1; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }

# THE system formula: a whole disk is a SYSTEM disk if ANY mountpoint in its
# block subtree (through md/LVM holders) is /, /boot, /boot/efi, or swap.
_disk_subtree_has_system() {                      # <disk-name> -> 0 if system
    local d=$1 mp
    while IFS= read -r mp; do
        case "$mp" in /|/boot|/boot/efi|"[SWAP]") return 0;; esac
    done < <(lsblk -nr -o MOUNTPOINT "/dev/$d" 2>/dev/null)
    lsblk -nr -o FSTYPE "/dev/$d" 2>/dev/null | grep -qx swap && return 0
    return 1
}

# Parse /proc/mdstat -> one "mdN level base1 base2 ..." line per active array.
_disk_mdstat_arrays() {
    local mdstat="${PROC_MDSTAT:-/proc/mdstat}" md _ rest tok level members
    local -a toks
    [[ -f "$mdstat" ]] || return 0
    while read -r md _ rest || [[ -n "$md" ]]; do
        [[ "$md" =~ ^md[0-9]+$ ]] || continue
        level=""; members=""; toks=(); read -ra toks <<<"$rest"
        for tok in ${toks[@]+"${toks[@]}"}; do
            case "$tok" in
                raid[0-9]*|linear|multipath|faulty) [[ -z "$level" ]] && level="$tok" ;;
                *\[*\]*) members+="$(_disk_base "${tok%%\[*}") " ;;
            esac
        done
        printf '%s %s %s\n' "$md" "${level:-unknown}" "${members% }"
    done < "$mdstat"
    return 0   # never hand a while-read EOF status (1) back to a bare caller under set -e
}

# Scan arrays once: a non-system all-NVMe array is the Q2 case; remember the
# first raid0 volume for the single-volume fallback.
_disk_scan_raid() {
    _DISK_DATA_ARRAY=""; _DISK_RAID0_VOL=""; _DISK_DATA_ARRAY_MEMBERS=()
    local md level members m sys allnvme
    while read -r md level members || [[ -n "$md" ]]; do
        [[ -n "$md" ]] || continue
        if _disk_subtree_has_system "$md"; then sys=1; else sys=0; fi
        if [[ "$sys" == "0" ]]; then
            for m in $members; do _DISK_DATA_ARRAY_MEMBERS+=("$m"); done
            allnvme=1; for m in $members; do _disk_is_nvme "$m" || allnvme=0; done
            [[ -z "$_DISK_DATA_ARRAY" && "$allnvme" == "1" ]] && _DISK_DATA_ARRAY="$md $level $members"
        fi
        [[ "$level" == "raid0" && -z "$_DISK_RAID0_VOL" ]] && _DISK_RAID0_VOL="$md $sys"
    done < <(_disk_mdstat_arrays)
    return 0   # ditto — a bare _disk_scan_raid under set -e must not inherit read's EOF 1
}

# Classify every physical disk into system / eligible / ineligible.
_disk_classify() {
    _DISK_ELIGIBLE=(); _DISK_SYSTEM=(); _DISK_INELIGIBLE=()
    local name bytes type model floor=$(( DISK_MIN_GB * 1000000000 ))
    while read -r name bytes type _ model || [[ -n "$name" ]]; do
        [[ "$type" == "disk" ]] || continue
        if _disk_subtree_has_system "$name"; then _DISK_SYSTEM+=("$name"); continue; fi
        if (( ${#_DISK_DATA_ARRAY_MEMBERS[@]} )) && _disk_in_list "$name" "${_DISK_DATA_ARRAY_MEMBERS[@]}"; then
            _DISK_INELIGIBLE+=("${name}|member of a data RAID array (resolved below)"); continue
        fi
        if ! _disk_is_nvme "$name"; then
            _DISK_INELIGIBLE+=("${name}|not NVMe — SATA/SAS can't sustain a mainnet validator"); continue
        fi
        if [[ -z "$bytes" || "$bytes" -lt "$floor" ]]; then
            _DISK_INELIGIBLE+=("${name}|below the ${DISK_MIN_GB} GB size floor"); continue
        fi
        _DISK_ELIGIBLE+=("$name")
    done < <(lsblk -dn -b -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null)
    return 0   # ditto
}

# --- table -------------------------------------------------------------------
_disk_table_line() {                              # tag name note -> formatted (info adds indent)
    local tag=$1 name=$2 note=$3 sz model
    sz=$(_disk_human "$(_disk_size_bytes "/dev/$name")")
    model=$(_disk_model "/dev/$name")
    printf '%-14s /dev/%-9s %9s  %-22s %s' "[$tag]" "$name" "$sz" "${model:0:22}" "$note"
}
_disk_show_table() {
    info "Detected storage:"
    local n entry nm reason
    if (( ${#_DISK_SYSTEM[@]} )); then for n in "${_DISK_SYSTEM[@]}"; do
        info "$(_disk_table_line system "$n" "OS (/, /boot or swap) — never a wipe target")"; done; fi
    if (( ${#_DISK_ELIGIBLE[@]} )); then for n in "${_DISK_ELIGIBLE[@]}"; do
        info "$(_disk_table_line eligible "$n" "NVMe, not system, >= ${DISK_MIN_GB} GB — selectable")"; done; fi
    if (( ${#_DISK_INELIGIBLE[@]} )); then for entry in "${_DISK_INELIGIBLE[@]}"; do
        nm="${entry%%|*}"; reason="${entry#*|}"
        info "$(_disk_table_line "not eligible" "$nm" "${reason} (not selectable)")"; done; fi
}

# --- guards ------------------------------------------------------------------
_disk_assert_not_root() {
    local dev=$1 root=$2
    [[ "$(_disk_base "$dev")" == "$root" ]] && fail "Refusing: ${dev} is the system/root disk"
    return 0
}
# Backstop applied to EVERY chosen data disk (menu pick OR --config path):
# not-root, not-system (RAID-aware), and NVMe. Foolproofs config-provided paths.
_disk_assert_eligible() {
    local dev=$1 root=$2 name; name=$(_disk_base "$dev")
    _disk_assert_not_root "$dev" "$root"
    _disk_subtree_has_system "$name" && fail "Refusing: ${dev} carries a system mount (/, /boot, or swap) — never a data target"
    _disk_is_nvme "$name" || fail "Refusing: ${dev} is not an NVMe device — SATA/SAS can't sustain a mainnet validator"
    return 0
}

# --- table + wipe report -----------------------------------------------------
_disk_wipe_report() {
    warn "These devices will be COMPLETELY ERASED (blkdiscard + mkfs.xfs):"
    local d
    for d in "$@"; do
        echo ""
        info "  ${d}   $(_disk_human "$(_disk_size_bytes "$d")")   $(_disk_model "$d")"
        lsblk "$d" 2>/dev/null | sed 's/^/      /'
        if _disk_mounted_anywhere "$d"; then warn "      ^^ currently MOUNTED — this destroys live data"; fi
    done
    echo ""
}

# --- fstab + swap + symlink (idempotent) -------------------------------------
_fstab_ensure() {                                 # _fstab_ensure <uuid> <mount>
    local uuid=$1 mount=$2
    ensure_line "$FSTAB_FILE" \
        "UUID=${uuid} ${mount} xfs ${XFS_MOUNT_OPTS} 0 2" \
        "[[:space:]]${mount}[[:space:]]"
}
_fstab_comment_swap() {                           # comment any active /swapfile line
    [[ -f "$FSTAB_FILE" ]] || return 0
    grep -qE '^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]' "$FSTAB_FILE" || return 0
    backup_file "$FSTAB_FILE"
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would comment swap entries in $FSTAB_FILE"; return 0; fi
    local tmp; tmp=$(_mktemp)
    awk '/^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]/{print "# "$0; next} {print}' "$FSTAB_FILE" >"$tmp"
    cat "$tmp" >"$FSTAB_FILE"; rm -f "$tmp"
    ok "Commented swap entries in fstab"
}
# Remove the swapfile — CLEANUP ONLY (swap is already off and _fstab_comment_swap
# disables it at boot), so it must be NON-FATAL: a restricted/immutable swapfile
# (chattr +i set by some providers, or swapoff failing under memory pressure so the
# file is still active) must not abort the install under set -e. Path overridable
# for tests. (F3)
_disk_remove_swapfile() {
    local swapf="${SWAPFILE:-/swapfile}"
    [[ -e "$swapf" ]] || return 0
    run rm -f "$swapf" 2>/dev/null \
        || { run chattr -i "$swapf" 2>/dev/null && run rm -f "$swapf" 2>/dev/null; } \
        || warn "Could not remove ${swapf} (immutable/restricted) — swap is OFF and fstab swap is commented, so this is harmless; continuing."
    return 0
}
_disk_symlink_home() {                            # target link
    local target=$1 link=$2 cur
    if [[ -L "$link" ]]; then
        cur=$(readlink "$link")
        [[ "$cur" == "$target" ]] && { ok "symlink ${link} -> ${target} already correct"; return 0; }
        warn "Replacing symlink ${link} (${cur} -> ${target})"; run rm -f "$link"
    elif [[ -e "$link" ]]; then
        fail "${link} exists and is not a symlink — move it aside before re-running (refusing to clobber data)"
    fi
    run ln -s "$target" "$link"
}

# --- resolution (interactive) ------------------------------------------------
# Numbered-menu pick over the eligible NVMe. Honors --config-provided
# ACCOUNTS_DISK/LEDGER_DISK (validated later by _disk_assert_eligible).
_disk_pick_two_nvme() {
    local -a el=("${_DISK_ELIGIBLE[@]}")
    if [[ -z "${ACCOUNTS_DISK:-}" || -z "${LEDGER_DISK:-}" ]]; then
        info "Eligible NVMe (pick by number):"
        local i; for i in "${!el[@]}"; do
            info "    $((i+1))) /dev/${el[$i]}  $(_disk_human "$(_disk_size_bytes "/dev/${el[$i]}")")  $(_disk_model "/dev/${el[$i]}")"
        done
        local -a nums=(); for i in "${!el[@]}"; do nums+=("$((i+1))"); done
        if [[ -z "${ACCOUNTS_DISK:-}" ]]; then
            ask_choice "Select ACCOUNTS disk (high random I/O) by number" "1" "${nums[@]}"
            ACCOUNTS_DISK="/dev/${el[$((REPLY-1))]}"
        fi
        local -a lnums=(); for i in "${!el[@]}"; do [[ "/dev/${el[$i]}" == "$ACCOUNTS_DISK" ]] && continue; lnums+=("$((i+1))"); done
        if [[ -z "${LEDGER_DISK:-}" ]]; then
            ask_choice "Select LEDGER disk by number" "${lnums[0]}" "${lnums[@]}"
            LEDGER_DISK="/dev/${el[$((REPLY-1))]}"
        fi
    fi
    info "Proposed mapping:  accounts=${ACCOUNTS_DISK}  ledger=${LEDGER_DISK}  (separate physical NVMe)"
}

# Q2: the data NVMe are joined in a RAID and the OS is on a separate disk.
_disk_handle_data_nvme_array() {
    local md level members
    read -r md level members <<<"$_DISK_DATA_ARRAY"
    warn "The data NVMe (${members}) are joined in software RAID ${level} (/dev/${md}); the OS is on a separate disk."
    info "A mainnet validator wants TWO separate volumes — accounts and ledger on different NVMe — so account hashing and ledger writes don't contend for I/O."
    info "  break  — stop /dev/${md} and reformat the NVMe as two separate XFS volumes (accounts + ledger). DESTROYS the array."
    info "  use    — keep the array as ONE shared volume (accounts+ledger together; suboptimal, OK for standby/backup nodes)."
    info "  cancel — make no changes; decide manually."
    ask_choice "Data-NVMe RAID — break into 2 / use as one / cancel" "break" break use cancel
    case "$REPLY" in
        break)
            local -a mem; read -ra mem <<<"$members"
            (( ${#mem[@]} == 2 )) || fail "Expected exactly 2 NVMe in /dev/${md}, found ${#mem[@]} — resolve manually"
            DISK_LAYOUT=two-nvme
            _DISK_BREAK_ARRAY="$md"
            ACCOUNTS_DISK="/dev/${mem[0]}"; LEDGER_DISK="/dev/${mem[1]}"
            info "Will break /dev/${md}, then accounts=${ACCOUNTS_DISK} ledger=${LEDGER_DISK}"
            ;;
        use)
            DISK_LAYOUT=raid-volume
            _disk_set_raid_volume "$md 0"
            ;;
        cancel)
            fail "Cancelled at the data-NVMe RAID decision — no changes made."
            ;;
    esac
}

_disk_set_raid_volume() {                         # "<md> <sysflag>"
    local md sys; read -r md sys <<<"$1"
    _DISK_RAID_MD="$md"
    if [[ "$sys" == "1" ]]; then
        SOLANA_HOME="${SOLANA_HOME:-/root/solana}"     # the array IS the / volume
        _DISK_RAID_MOUNT=""
        info "Using existing system RAID /dev/${md} as a single volume -> ${SOLANA_HOME}"
    else
        _DISK_RAID_MOUNT="$DATA_MOUNT"
        SOLANA_HOME="${SOLANA_HOME:-$DATA_MOUNT/solana}"
        info "Using existing data RAID /dev/${md} as a single volume -> ${SOLANA_HOME} (mounted at ${DATA_MOUNT})"
    fi
}

_disk_resolve() {
    local root; root=$(_disk_root_device)
    _disk_scan_raid
    _disk_classify
    _disk_show_table

    if [[ -n "$_DISK_DATA_ARRAY" ]]; then
        _disk_handle_data_nvme_array                       # sets DISK_LAYOUT (+disks or raid vars)
    elif (( ${#_DISK_ELIGIBLE[@]} >= 2 )); then
        DISK_LAYOUT=two-nvme
        _disk_pick_two_nvme
    elif [[ -n "$_DISK_RAID0_VOL" ]]; then
        DISK_LAYOUT=raid-volume
        _disk_set_raid_volume "$_DISK_RAID0_VOL"
    else
        DISK_LAYOUT=emergency
        warn "No eligible NVMe (>= ${DISK_MIN_GB} GB, non-system) and no usable RAID0 volume found."
        SOLANA_HOME="${SOLANA_HOME:-/root/solana}"
    fi

    # two-nvme (chosen directly OR via the Q2 break path): validate + record.
    if [[ "$DISK_LAYOUT" == "two-nvme" ]]; then
        [[ "$ACCOUNTS_DISK" == "$LEDGER_DISK" ]] && fail "Accounts and ledger must be DIFFERENT physical disks (I/O isolation)"
        _disk_assert_eligible "$ACCOUNTS_DISK" "$root"
        _disk_assert_eligible "$LEDGER_DISK" "$root"
        state_set accounts_disk "$ACCOUNTS_DISK"
        state_set ledger_disk "$LEDGER_DISK"
    fi
    state_set disk_layout "$DISK_LAYOUT"
}

# --- two-NVMe (destructive) --------------------------------------------------
_disk_already_setup() {
    have mountpoint || return 1
    mountpoint -q "$ACCOUNTS_MOUNT" 2>/dev/null && mountpoint -q "$LEDGER_MOUNT" 2>/dev/null
}

_disk_two_nvme() {
    if _disk_already_setup; then
        ok "Data disks already mounted at ${ACCOUNTS_MOUNT} and ${LEDGER_MOUNT} — skipping wipe"
        _disk_finalize_two_nvme
        return 0
    fi
    step "Disk wipe + XFS (DESTRUCTIVE)"
    _disk_wipe_report "$ACCOUNTS_DISK" "$LEDGER_DISK"
    if ! require_yes "PERMANENTLY ERASE ${ACCOUNTS_DISK} and ${LEDGER_DISK}? All data on them will be lost."; then
        fail "Disk wipe declined or not permitted (non-interactive never auto-wipes) — aborted before any destructive action"
    fi

    if [[ -n "${_DISK_BREAK_ARRAY:-}" ]]; then
        warn "Stopping software RAID /dev/${_DISK_BREAK_ARRAY} to free its NVMe members"
        run mdadm --stop "/dev/${_DISK_BREAK_ARRAY}"
        run mdadm --zero-superblock "$ACCOUNTS_DISK" "$LEDGER_DISK" || true
    fi

    run swapoff -a || true
    _disk_remove_swapfile
    _fstab_comment_swap

    local d
    for d in "$ACCOUNTS_DISK" "$LEDGER_DISK"; do
        _disk_umount_if_mounted "$d"
        run blkdiscard -f "$d"
        run mkfs.xfs -f "$d"
    done
    _disk_finalize_two_nvme
    ok "Data disks formatted (XFS) and mounted"
}

_disk_umount_if_mounted() {
    local d=$1 mp
    mp=$(lsblk -nr -o MOUNTPOINT "$d" 2>/dev/null | awk 'NF{print; exit}')
    [[ -n "$mp" ]] && run umount "$mp"
    return 0
}

_disk_finalize_two_nvme() {
    run mkdir -p "$LEDGER_MOUNT" "$ACCOUNTS_MOUNT"
    local uuid_l uuid_a
    uuid_l=$(blkid -s UUID -o value "$LEDGER_DISK" 2>/dev/null || true)
    uuid_a=$(blkid -s UUID -o value "$ACCOUNTS_DISK" 2>/dev/null || true)
    backup_file "$FSTAB_FILE"
    [[ -n "$uuid_l" ]] && _fstab_ensure "$uuid_l" "$LEDGER_MOUNT"
    [[ -n "$uuid_a" ]] && _fstab_ensure "$uuid_a" "$ACCOUNTS_MOUNT"
    run mount -a
    run mkdir -p "$LEDGER_MOUNT/solana" "$ACCOUNTS_MOUNT/solana"
    _disk_symlink_home "$LEDGER_MOUNT/solana" "$SOLANA_LINK"
    _disk_record_paths "$SOLANA_LINK" "$ACCOUNTS_MOUNT/solana/accounts"
    _disk_tune_xfs                  # XFS sysctl now that the filesystems are mounted
    run systemctl daemon-reload
}

# --- raid-volume (use an EXISTING array as a single shared volume) -----------
_disk_raid_volume() {
    local home="${SOLANA_HOME:-/root/solana}"
    step "Single-volume layout on existing RAID /dev/${_DISK_RAID_MD:-?}"
    warn "accounts + ledger will SHARE one volume — separate physical NVMe is strongly recommended for I/O isolation. This RAID path suits standby/backup nodes, not a primary mainnet validator."
    run swapoff -a || true
    _fstab_comment_swap
    [[ -n "${_DISK_RAID_MOUNT:-}" ]] && _disk_mount_data_array "/dev/${_DISK_RAID_MD}" "$_DISK_RAID_MOUNT"
    run mkdir -p "$home"/ledger "$home"/accounts "$home"/snapshots
    _disk_record_paths "$home" "$home/accounts"
    _disk_tune_xfs                  # XFS sysctl (the RAID volume is mkfs.xfs'd above)
    ok "RAID single-volume layout prepared at ${home}"
}
_disk_mount_data_array() {                        # <md-device> <mount> — ensure a data array is mounted
    local dev=$1 mount=$2 uuid
    if mountpoint -q "$mount" 2>/dev/null; then ok "${dev} already mounted at ${mount}"; return 0; fi
    if _disk_mounted_anywhere "$dev"; then
        warn "${dev} is mounted elsewhere — mount it at ${mount} manually, then re-run"; return 0
    fi
    _disk_wipe_report "$dev"
    require_yes "Format ${dev} (the RAID volume) as XFS and mount at ${mount}? Data on it will be lost." \
        || fail "Declined formatting ${dev} — aborted before any destructive action"
    run mkdir -p "$mount"
    run mkfs.xfs -f "$dev"
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
    backup_file "$FSTAB_FILE"
    [[ -n "$uuid" ]] && _fstab_ensure "$uuid" "$mount"
    run mount -a
}

# --- emergency (single system disk; LOUD warning) ---------------------------
_disk_emergency_layout() {
    local home="${SOLANA_HOME:-/root/solana}"
    step "EMERGENCY single-disk layout under ${home}"
    warn "==================================================================="
    warn "EMERGENCY MODE — no eligible NVMe and no usable RAID volume found."
    warn "ledger + accounts + snapshots will ALL share the system disk."
    warn "This is NOT recommended for mainnet: expect skipped slots under load."
    warn "Attach 2 NVMe (or a fast volume) and re-run 'deeploy.sh install --only 3'."
    warn "==================================================================="
    run swapoff -a || true
    _fstab_comment_swap
    run mkdir -p "$home"/ledger "$home"/accounts "$home"/snapshots
    _disk_record_paths "$home" "$home/accounts"
    _disk_tune_xfs                  # tolerant: warn-skips if the system disk isn't XFS
    ok "Emergency single-volume layout prepared at ${home}"
}

_disk_record_paths() {                            # solana_home accounts_dir
    local home=$1 accounts=$2
    state_set solana_home   "$home"
    state_set ledger_path   "$home/ledger"
    state_set snapshots_path "$home/snapshots"
    state_set accounts_path "$accounts"
}

# XFS sync-interval tuning. Lives in Phase 3 (NOT Phase 2's sysctl) because
# /proc/sys/fs/xfs/ only exists once an XFS filesystem is mounted, which happens
# here after mkfs.xfs. Two parts:
#   * a drop-in (22-agave-xfs.conf) + modules-load.d xfs preload, so the value
#     re-applies on EVERY boot — crucial because the isolation reboot (after this
#     phase) wipes any live sysctl, and systemd-sysctl runs before fstab mounts;
#   * apply it live NOW via the tolerant helper (warns, never aborts, if for some
#     reason the xfs subtree still isn't present).
_disk_tune_xfs() {
    step "XFS sync-interval tuning (fs.xfs.xfssyncd_centisecs=${XFS_SYNCD_CENTISECS})"
    write_file "$XFS_MODLOAD_FILE" \
"# Preload xfs so systemd-sysctl can apply fs.xfs.* on boot (DeePloy).
xfs
"
    write_file "$XFS_SYSCTL_FILE" \
"# XFS sync interval (default 3000 -> ${XFS_SYNCD_CENTISECS} = less overhead on accountsdb).
# Applied in Phase 3 after the XFS filesystems exist; re-applied each boot.
fs.xfs.xfssyncd_centisecs=${XFS_SYNCD_CENTISECS}
"
    apply_sysctl_file "$XFS_SYSCTL_FILE"    # tolerant; safe even if xfs subtree not yet visible
    ok "XFS tuning written (${XFS_SYSCTL_FILE}) and applied"
}

# --- orchestrator ------------------------------------------------------------
disk_run() {
    require_root
    _disk_resolve
    case "$DISK_LAYOUT" in
        two-nvme)    _disk_two_nvme ;;
        raid-volume) _disk_raid_volume ;;
        emergency)   _disk_emergency_layout ;;
        *)           fail "Unknown disk layout: ${DISK_LAYOUT}" ;;
    esac
}
