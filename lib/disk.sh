#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/disk.sh   (Phase 3: storage)
# Detect disks -> show table -> propose accounts/ledger mapping -> confirm ->
# (only then) blkdiscard + mkfs.xfs + mount + fstab + symlink. This is the most
# destructive phase, so every guard is explicit:
#   * the system/root disk is excluded from candidates and asserted-against;
#   * already-mounted targets are detected and the wipe is SKIPPED (no re-wipe);
#   * the wipe is gated behind require_yes (literal "yes") which IGNORES --yes
#     and REFUSES in non-interactive mode (--post-reboot) — so nothing auto-wipes;
#   * the exact devices + their current contents are shown before the prompt.
#
# Requires: common.sh sourced. lsblk/findmnt/blkid/mountpoint are read-only
# probes (mockable); all mutations go through run(); fstab path is overridable
# (FSTAB_FILE) for tests.
# ============================================================================

[[ -n "${_DEEPLOY_DISK_SOURCED:-}" ]] && return 0
_DEEPLOY_DISK_SOURCED=1

DISK_MIN_GB="${DISK_MIN_GB:-400}"                 # data-disk candidate size floor
LEDGER_MOUNT="${LEDGER_MOUNT:-/mnt/ledger}"
ACCOUNTS_MOUNT="${ACCOUNTS_MOUNT:-/mnt/accounts}"
SOLANA_LINK="${SOLANA_LINK:-/root/solana}"        # symlink -> <ledger>/solana (overridable for tests)
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
XFS_MOUNT_OPTS="defaults,noatime,logbufs=8,nofail"

# --- detection (read-only; mockable) -----------------------------------------
_disk_base() {                                    # nvme0n1p2 -> nvme0n1 ; sda2 -> sda
    local s=${1##*/}
    if   [[ "$s" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^([a-z]+)[0-9]+$ ]];             then printf '%s' "${BASH_REMATCH[1]}"
    else printf '%s' "$s"; fi
}
_disk_root_device() { _disk_base "$(findmnt -no SOURCE / 2>/dev/null)"; }
_disk_size_bytes()  { lsblk -dn -b -o SIZE "$1" 2>/dev/null | head -1; }
_disk_model()       { lsblk -dn -o MODEL "$1" 2>/dev/null | head -1; }
_disk_human()       { awk -v b="${1:-0}" 'BEGIN{printf "%.2f TB", b/1000000000000}'; }
_disk_mounted_anywhere() { [[ -n "$(lsblk -nr -o MOUNTPOINT "$1" 2>/dev/null | grep -v '^$' | head -1)" ]]; }

# Candidate data disks: whole disks, not the root disk, at/above the size floor.
# Emits "name bytes model" lines.
_disk_candidates() {
    local root=$1 name bytes type model floor=$(( DISK_MIN_GB * 1000000000 ))
    while read -r name bytes type _ model; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" == "$root" ]] && continue
        [[ -n "$bytes" && "$bytes" -ge "$floor" ]] || continue
        printf '%s %s %s\n' "$name" "$bytes" "$model"
    done < <(lsblk -dn -b -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null)
}

_disk_has_raid() {
    local mdstat="${PROC_MDSTAT:-/proc/mdstat}"
    { [[ -f "$mdstat" ]] && grep -qE '^md[0-9]' "$mdstat" 2>/dev/null; } && return 0
    have lvs && lvs >/dev/null 2>&1 && return 0
    return 1
}

_disk_assert_not_root() {
    local dev=$1 root=$2
    [[ "$(_disk_base "$dev")" == "$root" ]] && fail "Refusing: ${dev} is the system/root disk"
    return 0
}

# --- table + wipe report -----------------------------------------------------
_disk_show_table() {
    local root=$1; shift
    info "Detected storage:"
    info "  system/root disk: /dev/${root}  (never a wipe target)"
    local n
    for n in "$@"; do
        info "  data candidate:   /dev/${n}  $(_disk_human "$(_disk_size_bytes "/dev/$n")")  $(_disk_model "/dev/$n")"
    done
}

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
_disk_resolve() {
    local root; root=$(_disk_root_device)
    local -a cand=(); local name bytes model
    while read -r name bytes model; do cand+=("$name"); done < <(_disk_candidates "$root")

    if (( ${#cand[@]} >= 2 )); then
        DISK_LAYOUT=two-nvme
        _disk_show_table "$root" "${cand[@]}"
        ACCOUNTS_DISK="${ACCOUNTS_DISK:-/dev/${cand[0]}}"
        LEDGER_DISK="${LEDGER_DISK:-/dev/${cand[1]}}"
        info "Proposed mapping:  accounts=${ACCOUNTS_DISK}  ledger=${LEDGER_DISK}  (different physical disks)"
        if is_interactive; then
            ask "Accounts disk (high random I/O)" "$ACCOUNTS_DISK"; ACCOUNTS_DISK="$REPLY"
            ask "Ledger disk"                     "$LEDGER_DISK";   LEDGER_DISK="$REPLY"
        fi
        [[ "$ACCOUNTS_DISK" == "$LEDGER_DISK" ]] && fail "Accounts and ledger must be DIFFERENT physical disks (I/O isolation)"
        _disk_assert_not_root "$ACCOUNTS_DISK" "$root"
        _disk_assert_not_root "$LEDGER_DISK" "$root"
        state_set accounts_disk "$ACCOUNTS_DISK"
        state_set ledger_disk "$LEDGER_DISK"
    else
        DISK_LAYOUT=root
        warn "Fewer than 2 separate data disks (>= ${DISK_MIN_GB} GB) found."
        _disk_has_raid && warn "RAID/LVM detected — using a single-volume root layout."
        warn "Running ledger and accounts on the SAME volume is suboptimal — separate physical NVMe is strongly recommended."
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

    run swapoff -a || true
    [[ -e /swapfile ]] && run rm -f /swapfile
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
    mp=$(lsblk -nr -o MOUNTPOINT "$d" 2>/dev/null | grep -v '^$' | head -1)
    [[ -n "$mp" ]] && run umount "$mp"
    return 0
}

_disk_finalize_two_nvme() {
    run mkdir -p "$LEDGER_MOUNT" "$ACCOUNTS_MOUNT"
    local uuid_l uuid_a
    uuid_l=$(blkid -s UUID -o value "$LEDGER_DISK" 2>/dev/null)
    uuid_a=$(blkid -s UUID -o value "$ACCOUNTS_DISK" 2>/dev/null)
    backup_file "$FSTAB_FILE"
    [[ -n "$uuid_l" ]] && _fstab_ensure "$uuid_l" "$LEDGER_MOUNT"
    [[ -n "$uuid_a" ]] && _fstab_ensure "$uuid_a" "$ACCOUNTS_MOUNT"
    run mount -a
    run mkdir -p "$LEDGER_MOUNT/solana" "$ACCOUNTS_MOUNT/solana"
    _disk_symlink_home "$LEDGER_MOUNT/solana" "$SOLANA_LINK"
    _disk_record_paths "$SOLANA_LINK" "$ACCOUNTS_MOUNT/solana/accounts"
    run systemctl daemon-reload
}

# --- root layout (single disk / RAID) ----------------------------------------
_disk_root_layout() {
    local home="${SOLANA_HOME:-/root/solana}"
    step "Single-volume layout under ${home}"
    warn "ledger + accounts share one volume here — separate physical NVMe is strongly recommended for I/O isolation"
    run swapoff -a || true
    _fstab_comment_swap
    run mkdir -p "$home"/ledger "$home"/accounts "$home"/snapshots
    _disk_record_paths "$home" "$home/accounts"
    ok "Root layout prepared at ${home}"
}

_disk_record_paths() {                            # solana_home accounts_dir
    local home=$1 accounts=$2
    state_set solana_home   "$home"
    state_set ledger_path   "$home/ledger"
    state_set snapshots_path "$home/snapshots"
    state_set accounts_path "$accounts"
}

# --- orchestrator ------------------------------------------------------------
disk_run() {
    require_root
    _disk_resolve
    case "$DISK_LAYOUT" in
        two-nvme) _disk_two_nvme ;;
        root)     _disk_root_layout ;;
        *)        fail "Unknown disk layout: ${DISK_LAYOUT}" ;;
    esac
}
