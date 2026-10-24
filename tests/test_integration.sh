#!/usr/bin/env bash
# ============================================================================
# DeePloy — full-flow INTEGRATION test (the cross-phase seam check).
# Unit tests mock each module in isolation; this runs the real 0->8 chain on a
# simulated EPYC box (48-thread, mlx5_core, 2x NVMe) with EVERY external command
# mocked and EVERY path sandboxed — zero real side effects — and asserts that
# each phase's STATE output is the exact format the next phase reads.
#
# The walkthrough runs DRY_RUN=0 with full mocks, so every phase's state is
# real and can be asserted; "zero side effects" is guaranteed by the mocks + the
# temp sandbox. Before it, a literal `install --dry-run` runs on the untouched
# sandbox: its state threads through a temp shadow (R10-7e), and the sandbox
# must be byte-identical afterwards.
#
# Mocks shadow real commands and are invoked indirectly. SC2016: the printf'd
# mock scripts intentionally contain literal $1/$@ (single-quoted on purpose).
# shellcheck disable=SC2329,SC2034,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- sandbox EVERY writable path into the temp tree --------------------------
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
export GRUB_FILE="$WORK/etc/default/grub" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service" CPUFREQ_DEFAULT_FILE="$WORK/etc/default/cpufrequtils"
export SYSCTL_FILE="$WORK/21.conf" SYSCTL_SERVICE_FILE="$WORK/sysctl.service" LIMITS_FILE="$WORK/limits.conf" SYSTEM_CONF="$WORK/system.conf"
export FSTAB_FILE="$WORK/etc/fstab" LEDGER_MOUNT="$WORK/mnt/ledger" ACCOUNTS_MOUNT="$WORK/mnt/accounts" SOLANA_LINK="$WORK/root/solana"
export XFS_SYSCTL_FILE="$WORK/etc/22-agave-xfs.conf" XFS_MODLOAD_FILE="$WORK/etc/modules-load-xfs.conf"
export VALIDATOR_SH="$WORK/root/solana/validator.sh" SOLANA_SERVICE="$WORK/root/solana/solana.service"
export LOGROTATE_FILE="$WORK/logrotate"
export MLX5_IRQ_SCRIPT="$WORK/root/solana/mlx5-irq.sh" MLX5_IRQ_SERVICE="$WORK/mlx5.service"
export SOLANA_INSTALL_DIR="$WORK/install" MOSTLY_THRESHOLD_ROOT="$WORK/mct" RESUME_SERVICE_FILE="$WORK/deeploy-resume.service"
export SOLANA_BIN="$WORK/bin" OS_RELEASE_FILE="$WORK/os-release" PROC_CPUINFO="$WORK/cpuinfo" PROC_MEMINFO="$WORK/meminfo" PROC_MDSTAT="$WORK/mdstat"
export SSHD_CONFIG="$WORK/etc/sshd_config" NIC_TUNING_SCRIPT="$WORK/nic-tuning.sh" NIC_TUNING_SERVICE="$WORK/nic-tuning.service"
export FAIL2BAN_JAIL_DROPIN="$WORK/etc/fail2ban-deeploy-sshd.local"
# F3/F4: redirect the swapfile into the sandbox AND make it unremovable (a non-empty
# dir, so `rm -f` fails) — this keeps the -e assertions OFF the host's real /swapfile
# (which may be active -> EPERM) AND exercises the non-fatal swapfile-rm path: the
# disk phase must WARN and continue, not abort under set -Eeuo.
mkdir -p "$WORK/swapdir/keep"; export SWAPFILE="$WORK/swapdir"
# NB: do NOT pre-create $WORK/root/solana — phase 3 (disk) creates it as a symlink.
mkdir -p "$WORK/etc/default" "$WORK/etc" "$WORK/root" "$WORK/bin" "$WORK/install/releases"
printf '#Port 22\nPermitRootLogin yes\n' >"$SSHD_CONFIG"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0"\n' >"$GRUB_FILE"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$OS_RELEASE_FILE"
{ echo "model name : AMD EPYC 9354"; echo "flags : fpu aes sse2 avx"; for i in $(seq 0 47); do echo "processor : $i"; done; } >"$PROC_CPUINFO"
printf 'MemTotal:       395264000 kB\nSwapTotal:       2097152 kB\n' >"$PROC_MEMINFO"
: >"$WORK/mdstat"   # no software RAID on the simulated box (empty mdstat)
# mock solana toolchain binaries
printf '#!/bin/bash\ncase "$1" in new) for a in "$@";do [ "$p" = -o ]&&o="$a";p="$a";done; echo x>"$o";; pubkey) case "$2" in *unstaked*)echo Unstaked111111111111111111111111111111111;;*)echo Other1111111111111111111111111111111111111;;esac;; esac\n' >"$WORK/bin/solana-keygen"
printf '#!/bin/bash\nexit 0\n' >"$WORK/bin/solana"
chmod +x "$WORK/bin/solana-keygen" "$WORK/bin/solana"

# shellcheck source-path=SCRIPTDIR source=../deeploy.sh
source "$ROOT/deeploy.sh"

PASS=0; FAIL=0
check()      { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
sget() { state_get "$1" '<unset>'; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"

# --- mocks: reads (simulate the EPYC box) ------------------------------------
require_root() { :; }
# N8: the resume-unit ownership gate stats the real checkout (user-owned in the
# sandbox) — give it the safe answers a root-owned checkout would produce.
deeploy_path_uid()  { echo 0; }
deeploy_path_mode() { echo 755; }
uname()       { echo x86_64; }
nproc()       { echo 48; }
_cpu_total()  { echo 48; }
_cpu_siblings(){ local c=$1; if (( c<24 )); then echo "$c,$((c+24))"; else echo "$((c-24)),$c"; fi; }
ethtool()     { if [[ "$1" == -g ]]; then printf 'Ring parameters for %s:\nCurrent hardware settings:\nRX:\t\t\t1024\nTX:\t\t\t1024\n' "$2"
                else echo "driver: mlx5_core"; fi; }
ip()          { case "$*" in *"route show default"*) echo "default via 10.0.0.1 dev enp1s0";;
                              *"route get"*) echo "1.1.1.1 dev enp1s0 src 203.0.113.7";; *) echo "enp1s0 UP";; esac; }
lsblk()       { local last=${!#}; case "$*" in *"NAME,SIZE,TYPE,ROTA,MODEL"*) printf '%s\n' "nvme0n1 1920383410176 disk 0 SAMSUNG" "nvme1n1 1920383410176 disk 0 SAMSUNG" "sda 256060514304 disk 0 BOOT";;
                              *"-b -o SIZE"*) echo 1920383410176;; *"-o MODEL"*) echo SAMSUNG;;
                              *"-nr -o MOUNTPOINT"*) case "$last" in */sda) echo "/";; *) echo "";; esac;;
                              *"-nr -o FSTYPE"*) echo "";; *) echo "  (tree)";; esac; }
# findmnt is asked four different questions now, and a mock that answers them all
# with one string answers the wrong one: phase 3 asks whether ACCOUNTS_MOUNT and
# LEDGER_MOUNT are already mounted, and a blanket reply made this fixture look
# like a box whose two data mounts sit on the same device. This walkthrough is a
# FIRST install: nothing is mounted at either, which is what mountpoint() below
# already says.
findmnt() {
    local last=${!#}
    case "$*" in
        *"-no TARGET"*)
            case "$*" in
                *--target*) echo "/" ;;                # which filesystem holds a path
                *) case "$last" in
                       "$ACCOUNTS_MOUNT"|"$LEDGER_MOUNT") : ;;   # not mounted
                       *) echo "/" ;;
                   esac ;;
            esac ;;
        *"-no FSTYPE"*) : ;;
        *"-no SOURCE"*)
            case "$last" in
                # After 'mount -a': the disk that fstab names for the point
                # (UUID-<disk>, from blkid below). Before it, nothing.
                "$ACCOUNTS_MOUNT"|"$LEDGER_MOUNT")
                    grep -q '^mount -a' "$CALLS" || return 1
                    awk -v m="$last" '$2 == m {d = $1; sub(/^UUID=UUID-/, "/dev/", d); print d; f = 1} END {exit !f}' "$FSTAB_FILE" ;;
                *) echo "/dev/sda2" ;;                  # SOURCE of / — the root backstop
            esac ;;
        *) echo "/dev/sda2" ;;
    esac
}
blkid()       { local d=${!#}; echo "UUID-${d##*/}"; }
mountpoint()  { return 1; }
timedatectl() { echo yes; }
ss()          { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n'; return 0; }   # sshd listening on the new port
# Hermetic: _sshd_effective_ports runs a real `sshd -T` when unmocked — as
# root on a box with openssh-server it would return the HOST's ports instead
# of the sandbox fixture. Force the file-parse fallback (same as test_base).
sshd()        { return 1; }
df()          { printf 'FS 1G Used Avail Use Mounted\n/dev/x 1800G 10G 1790G 1%% /m\n'; }
ping()        { local h=${!#}; case "$h" in *frankfurt*) printf '%s\n' "0% packet loss" "rtt min/avg/max/mdev = 7/8.0/9/0.3 ms";; *) printf '%s\n' "100% packet loss"; return 1;; esac; }
curl()        { case "$*" in *getGenesisHash*) printf '{"result":"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"}';;
                             *http_code*) echo "curl $*" >>"$CALLS"; printf 200;;
                             *-o*) local i j o; for ((i=1;i<=$#;i++));do [ "${!i}" = -o ]&&{ j=$((i+1)); o="${!j}"; };done; [ -n "${o:-}" ]&&:>"$o";; *) :;; esac; }
# --- mocks: mutations (recorded, never executed) -----------------------------
ALLCALLS="$WORK/allcalls"; : >"$ALLCALLS"
for c in apt-get ufw systemctl blkdiscard mount swapoff umount mdadm cargo rustup setcap getcap update-grub sysctl cp logger sh git; do eval "${c}() { echo '${c}' \"\$*\" >>'$CALLS'; echo '${c}' >>'$ALLCALLS'; return 0; }"; done
mkfs.xfs() { echo "mkfs.xfs $*" >>"$CALLS"; echo mkfs.xfs >>"$ALLCALLS"; }
# The recorded systemctl calls that name the validator's own unit (solana or solana.service; solana-poh-pin.* and solana-sysctl.service are
# other units), minus the whole lines the caller allows. An allowlist and not a list of verbs: a call nobody thought of (disable --now,
# --no-block restart, mask) is listed too. <none> when there is nothing else. (The first allowed line is a sentinel: an empty allowlist
# file is no pattern at all.)
solana_unit_calls() {                # <calls file> [allowed line]...
    local calls=$1 allow="$WORK/solana-allow" out; shift
    printf '%s\n' '(allowlist)' "$@" >"$allow"
    out=$(grep -E '^systemctl( .*)? solana(\.service)?( |$)' "$calls" | grep -vxFf "$allow" || true)
    rm -f "$allow"; printf '%s' "${out:-<none>}"
}
# tuning_grub reads the GENERATED grub.cfg back before arming the reboot, so the
# walkthrough needs an update-grub that behaves like one. The candidate list is
# pinned at the fixture: the ubuntu runner has a real /boot/grub/grub.cfg, and
# falling through to it would have this suite assert against the runner's own
# bootloader config.
GCFG="$WORK/grub.cfg"; GRUB_CFG_CANDIDATES=("$GCFG")
update-grub() {
    echo "update-grub $*" >>"$CALLS"; echo update-grub >>"$ALLCALLS"
    local line; line=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_FILE" | tail -1)
    printf 'menuentry Ubuntu {\n\tlinux\t/boot/vmlinuz root=UUID=x ro %s\n}\n' "$line" >"$GCFG"
    return 0
}
ln()       { case "$*" in */etc/*) echo "ln $*" >>"$CALLS";; *) command ln "$@";; esac; }
require_yes() { return 0; }   # simulate the operator typing 'yes' to the disk wipe
# stub heavy build/network/wait subprocesses (their logic is unit-tested elsewhere)
for s in toolchain_deps toolchain_rust toolchain_anza_cli toolchain_fetch_source toolchain_apply_overlay \
         toolchain_inject_lto_profile toolchain_patch_cargo_script toolchain_compile toolchain_install_release \
         toolchain_write_threshold toolchain_setcap toolchain_verify start_wait_catchup; do eval "${s}() { :; }"; done
# verify probes: simulate a correctly-isolated, running node
_vf_pid(){ echo 12345; }; _vf_proc_limits(){ printf 'Max open files 2000000 2000000 files\nMax locked memory unlimited unlimited bytes\n'; }
_vf_proc_nice(){ echo -10; }; _vf_oom_score(){ echo -1000; }; _vf_blk_creation_thread(){ echo 999; }
_vf_isolated(){ sget isolated_set; }; _vf_governors(){ echo "cpu0 performance"; }; _vf_thp(){ echo "[never]"; }; _vf_ksm(){ echo 0; }; _vf_numa(){ echo 0; }
_vf_sysctl(){ case "$1" in net.core.rmem_max) echo 134217728;; fs.nr_open) echo 2000000;; esac; }; _vf_catchup(){ echo "caught up (us:100 them:100)"; }
_vf_nic(){ echo enp1s0; }; _vf_nic_bus(){ echo 0000:85:00.0; }; _vf_mlx5_irqs(){ echo "254 mlx5_comp0@pci:0000:85:00.0 0"; }
_vf_hugepages(){ echo 32; }; _vf_hugepage_fails(){ echo 0; }
_vf_log_first(){ echo 2026-10-05T14:00:00.000000000Z; }; _vf_log_last(){ echo 2026-10-05T14:45:00.000000000Z; }; _vf_bam_lines(){ :; }
# post-reboot isolation read (mock /sys agreeing with the recorded set)
_install_read_isolated(){ sget isolated_set; }; _install_read_cmdline(){ echo "isolcpus=domain,managed_irq,$(sget isolated_set)"; }

# --- config the operator would supply ----------------------------------------
export SSH_PORT=2222 JITO_TAG=v4.2.1-jito DZ_ENABLED=false ASSUME_YES=1
export VOTE_ACCOUNT_PUBKEY=Vote1111111111111111111111111111111111111111

echo "############ R10-7e: a literal 'install --dry-run' on a fresh box ############"
# main() as the operator runs it: -Eeuo, the traps, the dry-run state shadow.
# The real state dir does not exist yet, TMPDIR is in the sandbox, DoubleZero
# is on. The checkout gate is answered "safe" here; the control after the
# walkthrough drives the real predicates.
sandbox_sig() { ( cd "$WORK" && find . \( -path ./drytmp -o -path ./calls -o -path ./allcalls \) -prune -o -print | LC_ALL=C sort |
    while IFS= read -r p; do if [[ -f "$p" && ! -L "$p" ]]; then printf '%s %s\n' "$p" "$(cksum <"$p")"; else printf '%s\n' "$p"; fi; done ); }
# TMPDIR holds a canary: the exit trap must remove the shadow, never TMPDIR.
tmpleft() { if [[ -d "$1" ]]; then ( cd "$1" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' ); else printf '<no TMPDIR>'; fi; }
mkdir -p "$WORK/drytmp"; : >"$WORK/drytmp/canary"; SIG0=$(sandbox_sig)
DOUT=$( ( deeploy_root_surface_unsafe_reason() { return 0; }; deeploy_not_executable_reason() { return 0; }
          TMPDIR="$WORK/drytmp" DZ_ENABLED=true DEEPLOY_DEFAULT_CONF="$WORK/absent.conf" \
          DEEPLOY_STATE_DIR="$WORK/fresh/state" DEEPLOY_BACKUP_DIR="$WORK/fresh/backups" DEEPLOY_LOG_DIR="$WORK/fresh/logs" \
          main install --dry-run ) 2>&1 ); DRC=$?
check "dry-run: exits 0, stopped at the reboot gate"   "$DRC" "0"
check "dry-run: XDP planned from phase 0's NIC facts"  "$(grep -cF 'XDP cores=2,' <<<"$DOUT")" "1"
check "dry-run: DoubleZero rules planned (GRE, 44880)" "$(grep -cF '[dry-run] ufw allow proto gre from any to any' <<<"$DOUT")|$(grep -cF '[dry-run] ufw allow in on doublezero0 to any port 44880 proto udp' <<<"$DOUT")" "1|1"
check "dry-run: ufw limits the confirmed SSH port"     "$(grep -cF '[dry-run] ufw limit 2222/tcp' <<<"$DOUT")|$(grep -cF 'ufw limit 22/tcp' <<<"$DOUT")" "1|0"
check "dry-run: phase 6 renders (no MEV refusal)"      "$(grep -cF "[dry-run] would update $VALIDATOR_SH" <<<"$DOUT")|$(grep -cF 'MEV endpoints unset' <<<"$DOUT")" "1|0"
check "dry-run: phase 2's sysctl file planned, not missing" "$(grep -cF "[dry-run] would apply sysctl keys from $SYSCTL_FILE (tolerant)" <<<"$DOUT")|$(grep -cF "sysctl file not found: $SYSCTL_FILE" <<<"$DOUT")" "1|0"
check "dry-run: phase 3's XFS sysctl file planned, not missing" "$(grep -cF "[dry-run] would apply sysctl keys from $XFS_SYSCTL_FILE (tolerant)" <<<"$DOUT")|$(grep -cF "sysctl file not found: $XFS_SYSCTL_FILE" <<<"$DOUT")" "1|0"
check "dry-run: reaches the reboot gate"               "$(grep -cF '[dry-run] systemctl reboot' <<<"$DOUT")" "1"
check "dry-run: no phase 8"                            "$(grep -cF '━━━ Phase 8' <<<"$DOUT")" "0"
check "dry-run: the real state dir was never made"     "$([[ -e "$WORK/fresh" ]] && echo made || echo absent)" "absent"
check "dry-run: shadow removed, TMPDIR + canary kept"  "$(tmpleft "$WORK/drytmp")" "canary "
check "dry-run: the sandbox is byte-identical"         "$(sandbox_sig)" "$SIG0"
: >"$CALLS"; : >"$ALLCALLS"

echo "############ FULL-FLOW WALKTHROUGH (phases 0 -> 7, state threading) ############"
for p in 0 1 2 3 4 5 6 7; do
    P_FROM=$(wc -l <"$CALLS")
    run_phase "$p" >/dev/null 2>&1
    if [[ "$p" == 6 ]]; then sed -n "$((P_FROM + 1)),\$p" "$CALLS" >"$WORK/phase6.calls"; fi
    printf '— after phase %s (%s):\n' "$p" "$(phase_name "$p")"
    case "$p" in
        0) printf '    writes: nic_driver=%s retransmit_supported=%s retransmit_zero_copy=%s data_disk_count=%s\n' \
               "$(sget nic_driver)" "$(sget retransmit_supported)" "$(sget retransmit_zero_copy)" "$(sget data_disk_count)"
           printf '    region: suggested_bam_url=%s\n' "$(sget suggested_bam_url)" ;;
        2) printf '    reads retransmit_supported=%s -> writes xdp_cores=%s\n' "$(sget retransmit_supported)" "$(sget xdp_cores)"
           printf '    isolated_set=%s  irqaffinity=%s  reboot_required=%s\n' "$(sget isolated_set)" "$(sget irqaffinity)" "$(sget reboot_required)" ;;
        3) printf '    writes: solana_home=%s ledger_path=%s accounts_path=%s snapshots_path=%s\n' \
               "$(sget solana_home)" "$(sget ledger_path)" "$(sget accounts_path)" "$(sget snapshots_path)" ;;
        4) printf '    writes: jito_tag=%s\n' "$(sget jito_tag)" ;;
        5) printf '    writes: sync_identity=%s vote_account_pubkey=%s\n' "$(sget sync_identity)" "$(sget vote_account_pubkey)" ;;
        6) printf '    reads xdp_cores/paths -> generated validator.sh + solana.service + mlx5-irq service\n' ;;
        7) printf '    DZ_ENABLED=false -> skipped\n' ;;
    esac
done

echo ""
echo "############ SEAM ASSERTIONS (each phase reads the prior format) ############"
check "preflight->tuning: nic_driver = mlx5_core"          "$(sget nic_driver)" "mlx5_core"
check "preflight->tuning: retransmit_supported = 1"        "$(sget retransmit_supported)" "1"
check "preflight->validatorcfg: zero_copy = 1"             "$(sget retransmit_zero_copy)" "1"
check "tuning: no PoH core recorded"                       "$(sget poh_core)" "<unset>"
check "tuning: isolated_set = the XDP cores + siblings, 1-2,25-26" "$(sget isolated_set)" "1-2,25-26"
check "tuning: xdp_cores = 1-2 (-> RETRANSMIT)"            "$(sget xdp_cores)" "1-2"
check "tuning: reboot_required = 1"                        "$(sget reboot_required)" "1"
check "disk->validatorcfg: ledger_path"                   "$(sget ledger_path)" "$WORK/root/solana/ledger"
check "disk->validatorcfg: accounts_path (separate disk)" "$(sget accounts_path)" "$ACCOUNTS_MOUNT/solana/accounts"
check "disk->validatorcfg: snapshots on LEDGER side"      "$(sget snapshots_path)" "$WORK/root/solana/snapshots"
check "region->validatorcfg: bam_url chosen"              "$(sget bam_url)" "http://frankfurt.mainnet.bam.jito.wtf"
# R10-7d: the tag was asked of the jito repo and of Anza before phase 3 erased anything.
check "R10-7d: the build's tag checked before the first erase" "$(awk '/^git ls-remote .*refs\/tags\/v4.2.1-jito$/ {g = NR} /^curl .*release.anza.xyz\/v4.2.1\/install$/ {c = NR} /^(blkdiscard|mkfs\.xfs) / && !e {e = NR} END {print (g && c && e && g < e && c < e) ? "before" : "git=" g " curl=" c " erase=" e}' "$CALLS")" "before"
# XFS tuning belongs to Phase 3 (after the FS exists), NOT Phase 2's sysctl.
check "Phase 2 sysctl has NO fs.xfs key"                  "$(grep -c 'fs.xfs' "$SYSCTL_FILE")" "0"
check "R10-5: Phase 2 sysctl reserves the XDP UMEM's huge pages (2 cores, rings 1024/1024)" "$(grep -cx 'vm.nr_hugepages=32' "$SYSCTL_FILE")" "1"
check "Phase 3 wrote the XFS drop-in"                     "$(grep -c 'fs.xfs.xfssyncd_centisecs' "$XFS_SYSCTL_FILE")" "1"

echo ""
echo "############ GENERATED validator.sh threads the chain ############"
check_true "validator.sh generated"                  "[[ -f \"$VALIDATOR_SH\" ]]"
check "no PoH core in validator.sh: no --poh-pinned-cpu-core"  "$(grep -c -- 'poh-pinned-cpu-core' "$VALIDATOR_SH")" "0"
check "RETRANSMIT cpu-cores from xdp_cores (tuning)"           "$(grep -c -- '--xdp-cpu-cores "1-2"' "$VALIDATOR_SH")" "1"
check "zero-copy present (mlx5)"                              "$(grep -c -- '--xdp-zero-copy' "$VALIDATOR_SH")" "1"
check "XDP enabled on this box -> no --no-xdp"                "$(grep -c -- '--no-xdp' "$VALIDATOR_SH")" "0"
check "ledger path from disk state"                          "$(grep -c -- "--ledger \"$WORK/root/solana/ledger\"" "$VALIDATOR_SH")" "1"
check "accounts path from disk state"                        "$(grep -c -- "--accounts \"$ACCOUNTS_MOUNT/solana/accounts\"" "$VALIDATOR_SH")" "1"
check "bam-url from region state"                            "$(grep -c -- '--bam-url "http://frankfurt.mainnet.bam.jito.wtf"' "$VALIDATOR_SH")" "1"
check "vote-account from keys state"                         "$(grep -c -- '--vote-account "Vote1111' "$VALIDATOR_SH")" "1"
check "X1: every interpolated path is quoted (no bare --ledger /)" "$(grep -c -- '--ledger /' "$VALIDATOR_SH")" "0"
check_true "generated validator.sh is valid bash"           "bash -n \"$VALIDATOR_SH\""
check "mlx5-irq service generated (NIC layer)"               "$(grep -c 'Before=solana.service' "$MLX5_IRQ_SERVICE")" "1"
# R3/R4: phase 6 writes no PoH-pin script or unit, solana.service starts none,
# and phase 6 leaves the running validator alone.
POHF=""; for f in "$WORK/root/solana/set_poh_affinity.sh" "$WORK/root/solana/wait_and_pin_poh.sh" "$WORK/root/solana/solana-poh-pin.service" "$WORK/root/solana/solana-poh-pin.timer" \
    "$WORK/poh.service" "$WORK/poh.timer"; do [[ -e "$f" ]] && POHF+=" $f"; done
check "phase 6 wrote no PoH-pin script or unit"              "${POHF:-<none>}" "<none>"
check "solana.service starts no PoH-pin unit"                "$(grep -c 'poh-pin\|ExecStartPost' "$SOLANA_SERVICE")" "0"
check_true "phase 6 ran systemctl daemon-reload (the slice is the right one)" "(( $(grep -c '^systemctl daemon-reload' "$WORK/phase6.calls") >= 1 ))"
check "phase 6 enabled no poh-pin timer"                     "$(grep -c 'poh-pin' "$WORK/phase6.calls")" "0"
check "phase 6: the only systemctl call that names solana.service is the is-active question (allowlist)" \
      "$(solana_unit_calls "$WORK/phase6.calls" 'systemctl is-active --quiet solana.service')" "<none>"

echo ""
echo "############ R10-7e control: an unsafe checkout refuses at the gate, in a dry-run too ############"
# Phases 0-7 are done above, so install goes straight to the reboot gate and
# phase 0's copy of the check never runs. The REAL predicates now see a group/
# world-writable checkout. A dry-run must refuse there with the real run's own
# text — proof the gate runs in a dry-run and is not bypassed by the mock above.
SIG1=$(sandbox_sig)
UDRY=$( ( deeploy_path_mode() { echo 777; }
          TMPDIR="$WORK/drytmp" DEEPLOY_DEFAULT_CONF="$WORK/absent.conf" main install --dry-run ) 2>&1 ); UDRC=$?
check "control: the dry-run refuses (rc 1)"            "$UDRC" "1"
check "control: the dry-run wrote nothing"             "$(sandbox_sig)" "$SIG1"
UREAL=$( ( deeploy_path_mode() { echo 777; }
           DEEPLOY_DEFAULT_CONF="$WORK/absent.conf" main install ) 2>&1 ); URRC=$?
check "control: the real run refuses (rc 1)"           "$URRC" "1"
UD=$(grep -F 'refusing to install the resume service' <<<"$UDRY"); UR=$(grep -F 'refusing to install the resume service' <<<"$UREAL")
check "control: the refusal names the writable checkout" "$(grep -cF 'is group/world-writable (mode 777)' <<<"$UD")" "1"
check "control: the dry-run's refusal is the real run's" "$UD" "$UR"

echo ""
echo "############ REBOOT BOUNDARY (dispatcher) ############"
# Phases 0-7 done above; isolated_set + reboot_required set. The boundary should
# install the resume service and 'would reboot' (mocked), NOT run phase 8.
: >"$CALLS"
install_run >/dev/null 2>&1
check "resume service written (would install)"   "$(grep -c 'install --resume --post-reboot' "$RESUME_SERVICE_FILE")" "1"
check "resume service enabled (mocked systemctl)" "$(grep -c 'systemctl enable deeploy-resume.service' "$CALLS")" "1"
check "would reboot (mocked, not executed)"       "$(grep -c 'systemctl reboot' "$CALLS")" "1"
check "phase 8 NOT run before reboot"             "$(state_has phase-8 && echo y || echo n)" "n"
# The expected version is DERIVED from the source assignment (not hardcoded) so
# this pin can never drift from lib/common.sh again — rc1 shipped 0.1.0 in the
# code with a v0.1.0-rc1 tag, and the old hardcoded pin here matched the bug.
SRC_VERSION=$(sed -n 's/^DEEPLOY_VERSION="\${DEEPLOY_VERSION:-\([^}]*\)}"$/\1/p' "$ROOT/lib/common.sh")
check_true "version parses out of lib/common.sh"  "[[ -n \"$SRC_VERSION\" ]]"
check "install recorded deeploy_version in state" "$(sget deeploy_version)" "$SRC_VERSION"

echo ""
echo "############ POST-REBOOT RESUME -> verify isolation -> phase 8 ############"
: >"$CALLS"
POST_REBOOT=1 install_run >"$WORK/postreboot.out" 2>&1; POST_REBOOT=0
check "post-reboot: isolation verified, reboot_done set" "$(state_has reboot_done && echo y || echo n)" "y"
check "post-reboot: verify finds the block creation loop"  "$(grep -c 'Alpenglow block creation loop running' "$WORK/postreboot.out")" "1"
check "post-reboot: no PoH pinning, no PoH warning anywhere in phase 8" "$(grep -ci 'poh' "$WORK/postreboot.out")" "0"
check "post-reboot: phase 8 completed"                   "$(state_has phase-8 && echo y || echo n)" "y"
check "post-reboot: resume service disabled"             "$(grep -c 'systemctl disable deeploy-resume.service' "$CALLS")" "1"

echo ""
echo "############ MIGRATION: an older install re-run through phases 2 and 6, on a running validator ############"
# A box installed while DeePloy still pinned PoH: its isolated set carries the PoH core 10 and its sibling 34, the four
# PoH-pin files are there, validator.sh passes --poh-pinned-cpu-core and solana.service starts the pin unit. Each phase runs
# in its own shell, so that an older DeePloy (the red run) ends in failed checks and not in a dead suite.
SOLD="$WORK/root/solana"
state_set poh_core 10; state_set isolated_set "1-2,10,25-26,34"; state_set irqaffinity "0,3-9,11-24,27-33,35-47"
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0 amd_pstate=passive nvme_core.default_ps_max_latency_us=0 isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34 rcu_nocbs=1-2,10,25-26,34 irqaffinity=0,3-9,11-24,27-33,35-47"' >"$GRUB_FILE"
for f in set_poh_affinity.sh wait_and_pin_poh.sh solana-poh-pin.service solana-poh-pin.timer; do echo old >"$SOLD/$f"; done
printf '#!/bin/bash\nexec agave-validator --poh-pinned-cpu-core "10"\n' >"$VALIDATOR_SH"
printf '[Service]\nExecStart=%s\nExecStartPost=/bin/systemctl --no-block start solana-poh-pin.service\n' "$VALIDATOR_SH" >"$SOLANA_SERVICE"
: >"$CALLS"
( ONLY_PHASE=2; install_run ) >"$WORK/mig2.out" 2>&1
check "migration, phase 2: the GRUB line has the XDP set once and no PoH core or sibling" \
      "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26 ' "$GRUB_FILE")|$(grep -c '10,34' "$GRUB_FILE")|$(grep -o 'isolcpus=' "$GRUB_FILE" | wc -l | tr -d ' ')" "1|0|1"
check "migration, phase 2: the generated grub.cfg agrees"      "$(grep -c 'isolcpus=domain,managed_irq,1-2,25-26 ' "$GCFG")|$(grep -c '10,34' "$GCFG")" "1|0"
check "migration, phase 2: isolated_set and irqaffinity are the new ones" "$(sget isolated_set)|$(sget irqaffinity)" "1-2,25-26|0,3-24,27-47"
check "migration, phase 2: says the change takes effect at the next planned reboot" "$(grep -c 'next planned reboot' "$WORK/mig2.out")" "1"
check "migration, phase 2: a reboot is armed (the box is not rebooted by the phase)" "$(sget reboot_required)|$(grep -c 'systemctl reboot' "$CALLS")" "1|0"
( ONLY_PHASE=6; install_run ) >"$WORK/mig6.out" 2>&1
POHF=""; for f in set_poh_affinity.sh wait_and_pin_poh.sh solana-poh-pin.service solana-poh-pin.timer; do [[ -e "$SOLD/$f" ]] && POHF+=" $f"; done
check "migration, phase 6: the four PoH-pin files are removed"  "${POHF:-<none>}" "<none>"
check "migration, phase 6: one 'removed' line per file"         "$(grep -c ' removed ' "$WORK/mig6.out")" "4"
check "migration, phase 6: validator.sh without the flag, solana.service without ExecStartPost" "$(grep -c 'poh-pinned-cpu-core' "$VALIDATOR_SH")|$(grep -c 'ExecStartPost' "$SOLANA_SERVICE")" "0|0"
check "migration, phase 6: the timer and the service are disabled and stopped, then systemd reloaded" \
      "$(grep -c '^systemctl disable --now solana-poh-pin.timer' "$CALLS")|$(grep -c '^systemctl stop solana-poh-pin.service' "$CALLS")|$(awk '/^systemctl disable --now solana-poh-pin.timer/ {t = NR} /^systemctl daemon-reload/ && t && !r {r = NR} END {print (t && r && r > t) ? "reloaded after" : "no reload after"}' "$CALLS")" "1|1|reloaded after"
check "migration, phase 6: the new validator.sh waits for the next planned restart, a staked node for its standby" "$(grep -c 'new validator.sh takes effect at the next planned restart' "$WORK/mig6.out")|$(grep -c 'a staked node: move it to the standby first' "$WORK/mig6.out")" "1|1"
check "migration, phase 6: reset-failed for both PoH-pin units, once" \
      "$(grep -c '^systemctl reset-failed solana-poh-pin.service solana-poh-pin.timer$' "$CALLS")" "1"
# phases 2 and 6 ask whether solana.service is running (phase 6) and do nothing else with it: an allowlist of whole calls.
check "migration: the only systemctl call that names solana.service, in phases 2 and 6, is the is-active question (allowlist)" \
      "$(solana_unit_calls "$CALLS" 'systemctl is-active --quiet solana.service')" "<none>"
verify_run >"$WORK/migverify.out" 2>&1
check "migration: verify afterwards has no leftover and no PoH warning, no failure" "$(grep -c 'leftover PoH-pin' "$WORK/migverify.out")|$(grep -ci 'poh' "$WORK/migverify.out")|$(grep -c 'Verification: .* 0 failure' "$WORK/migverify.out")" "0|0|1"

echo ""
echo "############ ZERO REAL SIDE EFFECTS ############"
# Every mutation went to a mock or the temp sandbox. Prove nothing real ran and
# nothing was written outside $WORK.
MKFS_N=$(grep -c 'mkfs.xfs' "$ALLCALLS" 2>/dev/null || true); MKFS_N=${MKFS_N:-0}
check_true "disk wipe went to a MOCK (recorded, never executed)" "[[ \"$MKFS_N\" -ge 2 ]]"
check_true "no real /etc or /root artifacts created"            "[[ ! -e /etc/systemd/system/deeploy-resume.service && ! -e /root/solana/validator.sh ]]"
check_true "all generated artifacts live under the sandbox"     "[[ -f \"$VALIDATOR_SH\" && \"$VALIDATOR_SH\" == \"$WORK\"/* ]]"

echo ""
echo "############ literal --dry-run: run() prints, executes nothing ############"
DRY_RUN=1
DRYOUT=$( { run mkfs.xfs /dev/nvme0n1; run systemctl restart solana; } 2>&1 )
DRY_RUN=0
check "dry-run prints 'would' for mkfs"    "$(grep -c 'mkfs.xfs /dev/nvme0n1' <<<"$DRYOUT")" "1"
check "dry-run prints 'would' for restart" "$(grep -c 'systemctl restart solana' <<<"$DRYOUT")" "1"
check "dry-run marks them as dry-run"      "$(grep -c 'dry-run' <<<"$DRYOUT")" "2"

echo ""
echo "############ PRODUCTION FLAGS: full install path survives set -Eeuo pipefail ############"
# THE structural guard. The disk + catchup bug class slipped through because the
# whole suite runs 'set -uo pipefail' (no -e); only the real main() sets -Eeuo.
# Re-run the ENTIRE install under main()'s exact flags. Heavy build + the catchup
# poll stay stubbed (covered by their own tests); this proves every phase's control
# flow survives errexit+pipefail (a function ending in while-read returning EOF=1,
# or a var=$(pipeline) aborting on an expected non-zero, would fail here).
rm -rf "${DEEPLOY_STATE_DIR:?}/state.d"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"
( set -Eeuo pipefail; install_run ) >/dev/null 2>&1
check "install_run survives set -Eeuo pipefail (phases 0-7 + reboot gate)" "$?" "0"
check "reached the reboot gate under -e"  "$(grep -c 'install --resume --post-reboot' "$RESUME_SERVICE_FILE")" "1"
check "F3/F4: disk phase completed under -e despite an unremovable swapfile" "$(state_has phase-3 && echo y || echo n)" "y"
( set -Eeuo pipefail; POST_REBOOT=1 install_run ) >/dev/null 2>&1
check "POST_REBOOT install_run survives set -Eeuo pipefail (phase 8)" "$?" "0"
check "phase 8 completed under -e"        "$(state_has phase-8 && echo y || echo n)" "y"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
