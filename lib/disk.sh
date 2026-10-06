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
#   The system volume (3, and 2 when the array carries /) takes the ledger only
#   after a typed 'yes', and never on a box laid out on data disks
#   (_disk_system_volume_gate).
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
# Every mountpoint in a disk's subtree, one per line. The predicate above answers
# whether there is one; a refusal has to be able to NAME it, or the operator is
# told to unmount something without being told what.
_disk_mountpoints() { lsblk -nr -o MOUNTPOINT "$1" 2>/dev/null | awk 'NF'; }
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

# THE checkout formula, deliberately the same shape as the system one: resolve the
# mount point that CONTAINS the checkout, then ask each disk's block subtree
# whether it carries that mount point. Going through lsblk holders is what makes
# it RAID/LVM-aware for free — mapping the device downward instead would turn
# /dev/md0 into the string "md" and let the real members through, which is the
# exact bug the system formula was rewritten to kill.
#
# Fail-closed, and it SETS A GLOBAL rather than printing one. That is not style:
# a helper that prints its answer must be called as $( ), which is a subshell, and
# fail()'s exit there kills only the subshell — the caller reads an empty string
# and keeps going. This function was written that way first and the suite caught
# it refusing out loud while classification carried on. findmnt is itself an
# external command, and an unanswerable question here is not a reason to continue:
# the next phase erases disks. A missing findmnt, an unparseable answer, or an
# unset DEEPLOY_DIR each stop the run rather than widen the candidate set.
_DISK_CK_MOUNT=""                                 # set by _disk_require_checkout_mount
_disk_require_checkout_mount() {                  # dies in the CALLER's shell, by design
    local dir="${DEEPLOY_DIR:-}"
    _DISK_CK_MOUNT=""
    [[ -n "$dir" ]] || fail "Refusing: DEEPLOY_DIR is unset, so the disk holding this checkout cannot be identified. This phase erases disks; it will not guess."
    have findmnt || fail "Refusing: findmnt is not installed, so the disk holding the checkout (${dir}) cannot be identified. This phase erases disks; it will not guess. Install util-linux and re-run."
    _DISK_CK_MOUNT=$(findmnt -no TARGET --target "$dir" 2>/dev/null) || _DISK_CK_MOUNT=""
    [[ -n "$_DISK_CK_MOUNT" ]] || fail "Refusing: findmnt could not resolve which filesystem holds the checkout (${dir}). This phase erases disks; it will not guess."
}

_disk_subtree_has_mount() {                       # <disk-name> <mountpoint> -> 0 if carried
    local d=$1 want=$2 mp
    # An empty mount point means the resolution above was skipped, and answering
    # "not carried" would hand the caller a disk that is merely unidentified. Both
    # call sites pass $_DISK_CK_MOUNT after a bare _disk_require_checkout_mount, so
    # neither of them can reach this line — which is the point: "by construction"
    # has to be the construction, not a convention two call sites happen to keep.
    # The suite reaches it directly, and asserts that it kills the caller.
    [[ -n "$want" ]] || fail "Refusing: asked whether /dev/${d} carries the checkout without a resolved mount point. That is a bug in this module, not a condition to tolerate before a wipe."
    while IFS= read -r mp; do
        [[ "$mp" == "$want" ]] && return 0
    done < <(lsblk -nr -o MOUNTPOINT "/dev/$d" 2>/dev/null)
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
    _disk_require_checkout_mount                  # dies rather than skip; see the formula above
    while read -r name bytes type _ model || [[ -n "$name" ]]; do
        [[ "$type" == "disk" ]] || continue
        if _disk_subtree_has_system "$name"; then _DISK_SYSTEM+=("$name"); continue; fi
        if _disk_subtree_has_mount "$name" "$_DISK_CK_MOUNT"; then
            _DISK_INELIGIBLE+=("${name}|holds this DeePloy checkout (${_DISK_CK_MOUNT}) — erasing it destroys the running install"); continue
        fi
        if _disk_mounted_anywhere "/dev/$name"; then
            _DISK_INELIGIBLE+=("${name}|mounted at $(_disk_mountpoints "/dev/$name" | tr '\n' ' ')— unmount it yourself if it is really a target"); continue
        fi
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
    _disk_require_checkout_mount
    _disk_subtree_has_mount "$name" "$_DISK_CK_MOUNT" && fail "Refusing: ${dev} carries the filesystem holding this DeePloy checkout (${DEEPLOY_DIR:-?}) — the install is running from it, and erasing it takes the installer with it"
    # A mounted non-system disk is refused outright, with no exception for mounts
    # DeePloy itself made. State records disk NAMES (nvme0n1), and those are not
    # stable across reboots, so an exception would either refuse the wrong disk
    # after renumbering or need the whole identification redone. Reformatting a
    # ledger on a staked box is deliberate; the explicit umount is the friction
    # that makes it so. --yes does not reach here: this is a fail, not a prompt.
    if _disk_mounted_anywhere "$dev"; then
        fail "Refusing: ${dev} is mounted at $(_disk_mountpoints "$dev" | tr '\n' ' ')— erasing it destroys whatever is live there. Unmount it yourself and run again."
    fi
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

# --- was this box laid out on data disks? ------------------------------------
# The answer has to be true, so it is written only where it is: by the data
# layouts, after the mount check has shown the data filesystems mounted from
# their own devices. disk_layout cannot answer it. It is recorded before the wipe
# question, so after a declined wipe it claims a layout that never happened, and
# a later --only 3 or --force rewrites it before its own question. data_layout
# is not in the export/import map either: a conf from another box says nothing
# about these disks. A box laid out before the key existed (rc9 and older) has
# phase 3 done and its accounts path on a data mount: _disk_record_paths runs at
# the end of a data layout, and the system-volume layouts record /root/solana.
# A deliberate re-layout clears the record by writing "none" into the key, which
# also stops that fallback from answering.
_disk_laid_out() {                                # stdout: two-nvme | raid-volume, or nothing
    local m acc
    if state_has data_layout; then
        m=$(state_get data_layout "")
        [[ "$m" == "none" ]] || printf '%s' "$m"
        return 0
    fi
    is_phase_done 3 || return 0
    acc=$(state_get accounts_path "")
    case "$acc" in
        "$ACCOUNTS_MOUNT"/*) printf 'two-nvme' ;;
        "$DATA_MOUNT"/*)     printf 'raid-volume' ;;
    esac
    return 0
}

# Ledger and accounts go onto the system volume only with the operator's own
# 'yes' (require_yes: --yes does not answer it, and without a tty it refuses),
# and never on a box that was laid out on data disks. There the disks that were
# here are not here now, and this phase cannot find out why: the system-volume
# layouts write no filesystem, but they repoint solana_home, ledger_path,
# snapshots_path and accounts_path at the system volume through
# _disk_record_paths, and the real ledger would sit on a disk nothing
# references. Both paths onto the system volume come through here: the
# emergency layout, and a RAID0 array that carries / itself.
_disk_system_volume_gate() {                      # <the volume, for the operator> <why it is the only one>
    local prev; prev=$(_disk_laid_out)
    if [[ -n "$prev" ]]; then
        fail "Refusing: this box was laid out on data disks (${prev}), and no eligible data disk or data RAID volume is visible now. Putting the ledger and accounts on ${1} would repoint their paths at ${SOLANA_HOME} and leave the real data unreferenced. Attach the data disks and run again. If this box really is being laid out again, clear the record first: echo none > $(_state_file data_layout)"
    fi
    warn "$2"
    warn "The ledger, accounts and snapshots would share ${1} (${SOLANA_HOME}) with the OS. Not recommended for mainnet: expect skipped slots under load."
    require_yes "Put the ledger, accounts and snapshots on ${1}?" \
        || fail "Declined (or no terminal to ask on): nothing was changed. Attach data disks — 2 NVMe, or a data RAID volume — and run again."
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
        [[ -n "$_DISK_RAID_MOUNT" ]] || _disk_system_volume_gate \
            "/dev/${_DISK_RAID_MD}, the RAID0 array that also carries /" \
            "Fewer than 2 eligible NVMe, and the only RAID0 array, /dev/${_DISK_RAID_MD}, is the system volume."
    else
        SOLANA_HOME="${SOLANA_HOME:-/root/solana}"
        _disk_system_volume_gate "the system disk" \
            "No eligible NVMe (>= ${DISK_MIN_GB} GB, non-system) and no usable RAID0 volume found."
        DISK_LAYOUT=emergency
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

# --- is this a re-run of a box we already laid out? ---------------------------
# Asked BEFORE _disk_resolve, and that ordering is the whole point. "Which disk
# may be erased?" and "is this our own box again?" are different questions, and
# answering the first one first is what broke: the X2 refusal put DeePloy's own
# mounted data disks into the ineligible list, no layout resolved to two-nvme,
# and _disk_two_nvme — which holds the skip-the-wipe branch — was never reached.
# The run fell through to the emergency layout and rewrote the recorded paths
# onto the system disk. Measured on fixtures, not deduced.
#
# It also closes an older hazard that has nothing to do with X2. A re-run used to
# ask the menu again, and _disk_finalize_two_nvme writes fstab keyed by MOUNT
# POINT, so answering in the opposite order replaced each mount's line with the
# other disk's UUID and the two swapped after the next reboot. Measured on a
# fixture: /mnt/accounts -> the ledger UUID and /mnt/ledger -> the accounts UUID.
# Taking each device FROM the mount point it is actually mounted at cannot
# produce that, because the answer comes from the kernel rather than a prompt.
_disk_mount_source() { findmnt -no SOURCE "$1" 2>/dev/null || true; }   # empty = not mounted; 0 always, for $( )
_disk_mount_fstype() { findmnt -no FSTYPE "$1" 2>/dev/null; }
_disk_is_mounted()   { [[ -n "$(findmnt -no TARGET "$1" 2>/dev/null)" ]]; }

# Whole NVMe disk, not a partition, not a mapper device, not a bind mount. A
# bind mount's SOURCE carries a [subpath] and fails this by construction.
_disk_is_whole_nvme() { [[ "${1##*/}" =~ ^nvme[0-9]+n[0-9]+$ ]]; }

_disk_adopt_existing_layout() {                   # 0 = adopted (caller returns), 1 = not a re-run
    have findmnt || fail "Refusing: findmnt is not installed, so whether ${ACCOUNTS_MOUNT} and ${LEDGER_MOUNT} are already mounted cannot be answered. This phase erases disks; it will not guess."
    local a_m l_m; a_m=$(_disk_is_mounted "$ACCOUNTS_MOUNT" && echo y || echo n)
    l_m=$(_disk_is_mounted "$LEDGER_MOUNT" && echo y || echo n)
    [[ "$a_m" == "n" && "$l_m" == "n" ]] && return 1        # nothing mounted: a first install

    # Half a layout is not a layout. Refusing here rather than falling through:
    # the fall-through is what put a working box into the emergency layout.
    if [[ "$a_m" != "$l_m" ]]; then
        local one; [[ "$a_m" == "y" ]] && one="$ACCOUNTS_MOUNT" || one="$LEDGER_MOUNT"
        fail "Refusing: ${one} is mounted but its counterpart is not, so this is neither a clean install nor a re-run of a layout DeePloy made. Mount both, or unmount ${one}, then run again."
    fi

    local a_src l_src a_fs l_fs
    a_src=$(_disk_mount_source "$ACCOUNTS_MOUNT"); l_src=$(_disk_mount_source "$LEDGER_MOUNT")
    a_fs=$(_disk_mount_fstype "$ACCOUNTS_MOUNT");  l_fs=$(_disk_mount_fstype "$LEDGER_MOUNT")
    local why=""
    [[ -n "$a_src" && -n "$l_src" ]]                 || why="findmnt could not name the device behind one of them"
    [[ -z "$why" ]] && { [[ "$a_src" != "$l_src" ]]  || why="both are the same device (${a_src}); accounts and ledger must be different physical disks"; }
    [[ -z "$why" ]] && { _disk_is_whole_nvme "$a_src" || why="${ACCOUNTS_MOUNT} is backed by ${a_src}, which is not a whole NVMe disk"; }
    [[ -z "$why" ]] && { _disk_is_whole_nvme "$l_src" || why="${LEDGER_MOUNT} is backed by ${l_src}, which is not a whole NVMe disk"; }
    [[ -z "$why" ]] && { [[ "$a_fs" == "xfs" ]]      || why="${ACCOUNTS_MOUNT} is ${a_fs:-of unknown type}, not xfs"; }
    [[ -z "$why" ]] && { [[ "$l_fs" == "xfs" ]]      || why="${LEDGER_MOUNT} is ${l_fs:-of unknown type}, not xfs"; }
    [[ -z "$why" ]] && { _disk_subtree_has_system "${a_src##*/}" && why="${a_src} carries a system mount"; }
    [[ -z "$why" ]] && { _disk_subtree_has_system "${l_src##*/}" && why="${l_src} carries a system mount"; }
    [[ -n "$why" ]] && fail "Refusing: ${ACCOUNTS_MOUNT} and ${LEDGER_MOUNT} are mounted, but this is not a layout DeePloy would have made — ${why}. Unmount them if these disks really are the targets, then run again."

    ACCOUNTS_DISK="$a_src"; LEDGER_DISK="$l_src"
    DISK_LAYOUT=two-nvme
    ok "Data disks already mounted: ${ACCOUNTS_MOUNT} on ${ACCOUNTS_DISK}, ${LEDGER_MOUNT} on ${LEDGER_DISK} — adopting them, nothing is erased"
    state_set accounts_disk "$ACCOUNTS_DISK"
    state_set ledger_disk   "$LEDGER_DISK"
    state_set disk_layout   "$DISK_LAYOUT"
    _disk_finalize_two_nvme
    return 0
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
        _disk_assert_not_mounted "$d"
        run blkdiscard -f "$d"
        run mkfs.xfs -f "$d"
    done
    _disk_finalize_two_nvme
    ok "Data disks formatted (XFS) and mounted"
}

# This unmounted the disk one line before blkdiscard. Both refusals above have to
# hold for control to arrive here, so an automatic umount at this point protects
# nothing and quietly disarms them: weaken either one and a live filesystem is
# unmounted and erased without a word. A last line of defence has to refuse.
_disk_assert_not_mounted() {
    local d=$1 mp
    mp=$(_disk_mountpoints "$d" | tr '\n' ' ')
    [[ -z "$mp" ]] || fail "Refusing: ${d} is still mounted at ${mp}— refusing to unmount it here, one line before it is erased. Unmount it yourself and run again."
    return 0
}

# The data directories are created, and their paths recorded, only on the
# filesystem they were laid out on. 'mount -a' is silent about a point it did not
# mount: with an empty UUID no fstab line was written at all, and nofail skips a
# device that is not there. The point is then a plain directory on the root
# filesystem, the mkdir after it puts the data directories there, and the paths
# are recorded. agave creates whatever is missing itself
# (validator/src/commands/run/args.rs 79-85 at c21f9074), so the validator would
# write its ledger to the system disk without a word. Hence: an empty UUID
# refuses, and after 'mount -a' each point is asked on its own which device it is
# mounted from — findmnt given two mount points prints nothing at all.
_disk_require_uuid() {                            # <device> <uuid> <mountpoint>
    [[ -n "$2" ]] && return 0
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} ${1} has no filesystem UUID yet (mkfs.xfs did not run); a real run refuses here if blkid still finds none"
        return 0
    fi
    fail "Refusing: blkid reports no filesystem UUID on ${1}, so no fstab line can be written for ${3}, and ${3} would stay a directory on the root filesystem. Nothing was created under it. Check ${1} with blkid, then run again."
}
_disk_require_mounted_from() {                    # <mountpoint> <device>, after 'mount -a'
    local mp=$1 dev=$2 src
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would check that ${mp} is mounted from ${dev}"; return 0; fi
    src=$(_disk_mount_source "$mp")
    [[ -n "$src" ]] || fail "Refusing: ${mp} is not mounted after 'mount -a', so the data directories would be created on the root filesystem. Nothing was created under it. Check the ${mp} line in ${FSTAB_FILE} and ${dev}, then run again."
    [[ "$src" == "$dev" ]] || fail "Refusing: ${mp} is mounted from ${src}, not from ${dev}. Nothing was created under it. Unmount ${mp} if ${dev} is the intended device, then run again."
    return 0
}

_disk_finalize_two_nvme() {
    run mkdir -p "$LEDGER_MOUNT" "$ACCOUNTS_MOUNT"
    local uuid_l uuid_a
    uuid_l=$(blkid -s UUID -o value "$LEDGER_DISK" 2>/dev/null || true)
    uuid_a=$(blkid -s UUID -o value "$ACCOUNTS_DISK" 2>/dev/null || true)
    _disk_require_uuid "$LEDGER_DISK"   "$uuid_l" "$LEDGER_MOUNT"
    _disk_require_uuid "$ACCOUNTS_DISK" "$uuid_a" "$ACCOUNTS_MOUNT"
    backup_file "$FSTAB_FILE"
    [[ -n "$uuid_l" ]] && _fstab_ensure "$uuid_l" "$LEDGER_MOUNT"
    [[ -n "$uuid_a" ]] && _fstab_ensure "$uuid_a" "$ACCOUNTS_MOUNT"
    run mount -a
    _disk_require_mounted_from "$LEDGER_MOUNT"   "$LEDGER_DISK"
    _disk_require_mounted_from "$ACCOUNTS_MOUNT" "$ACCOUNTS_DISK"
    run mkdir -p "$LEDGER_MOUNT/solana" "$ACCOUNTS_MOUNT/solana"
    _disk_symlink_home "$LEDGER_MOUNT/solana" "$SOLANA_LINK"
    _disk_record_paths "$SOLANA_LINK" "$ACCOUNTS_MOUNT/solana/accounts"
    state_set data_layout two-nvme  # only now: both mounted from their own disks (above)
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
    # A data array, mounted from itself (_disk_mount_data_array checked), lays
    # the box out on data disks; the array that carries / does not.
    if [[ -n "${_DISK_RAID_MOUNT:-}" ]]; then state_set data_layout raid-volume; fi
    _disk_tune_xfs                  # XFS sysctl (the RAID volume is mkfs.xfs'd above)
    ok "RAID single-volume layout prepared at ${home}"
}
_disk_mount_data_array() {                        # <md-device> <mount> — ensure a data array is mounted
    local dev=$1 mount=$2 uuid src
    # Already mounted counts only when it is this array: anything else under
    # ${mount}, a bind of a directory on / included, would take the ledger.
    src=$(_disk_mount_source "$mount")
    if [[ -n "$src" ]]; then
        [[ "$src" == "$dev" ]] || fail "Refusing: ${mount} is already mounted from ${src}, not from ${dev}, so the ledger and accounts would go there. Unmount ${mount} if ${dev} is the intended volume, then run again."
        ok "${dev} already mounted at ${mount}"; return 0
    fi
    # Mounted elsewhere, the array leaves ${mount} a directory on the root
    # filesystem. This used to warn and carry on into the mkdir under it.
    if _disk_mounted_anywhere "$dev"; then
        fail "Refusing: ${dev} is mounted at $(_disk_mountpoints "$dev" | tr '\n' ' ')— not at ${mount}, so the data directories would be created on the root filesystem. Mount it at ${mount} yourself, then run again."
    fi
    _disk_wipe_report "$dev"
    require_yes "Format ${dev} (the RAID volume) as XFS and mount at ${mount}? Data on it will be lost." \
        || fail "Declined formatting ${dev} — aborted before any destructive action"
    run mkdir -p "$mount"
    run mkfs.xfs -f "$dev"
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
    _disk_require_uuid "$dev" "$uuid" "$mount"
    backup_file "$FSTAB_FILE"
    [[ -n "$uuid" ]] && _fstab_ensure "$uuid" "$mount"
    run mount -a
    _disk_require_mounted_from "$mount" "$dev"
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
    _disk_adopt_existing_layout && return 0        # a re-run is a different question
    _disk_resolve
    case "$DISK_LAYOUT" in
        two-nvme)    _disk_two_nvme ;;
        raid-volume) _disk_raid_volume ;;
        emergency)   _disk_emergency_layout ;;
        *)           fail "Unknown disk layout: ${DISK_LAYOUT}" ;;
    esac
}
