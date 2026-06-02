#!/usr/bin/env bash
# ============================================================================
# DeePloy — full-flow INTEGRATION test (the cross-phase seam check).
# Unit tests mock each module in isolation; this runs the real 0->8 chain on a
# simulated EPYC box (48-thread, mlx5_core, 2x NVMe) with EVERY external command
# mocked and EVERY path sandboxed — zero real side effects — and asserts that
# each phase's STATE output is the exact format the next phase reads.
#
# Why not a literal --dry-run: dry-run writes no state (by design), so the chain
# can't thread through it. This runs DRY_RUN=0 with full mocks so state threads;
# "zero side effects" is guaranteed by the mocks + the temp sandbox.
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
export GRUB_FILE="$WORK/etc/default/grub" PERF_SCRIPT_FILE="$WORK/perf.sh" PERF_SERVICE_FILE="$WORK/perf.service"
export SYSCTL_FILE="$WORK/21.conf" SYSCTL_SERVICE_FILE="$WORK/sysctl.service" LIMITS_FILE="$WORK/limits.conf" SYSTEM_CONF="$WORK/system.conf"
export FSTAB_FILE="$WORK/etc/fstab" LEDGER_MOUNT="$WORK/mnt/ledger" ACCOUNTS_MOUNT="$WORK/mnt/accounts" SOLANA_LINK="$WORK/root/solana"
export XFS_SYSCTL_FILE="$WORK/etc/22-agave-xfs.conf" XFS_MODLOAD_FILE="$WORK/etc/modules-load-xfs.conf"
export VALIDATOR_SH="$WORK/root/solana/validator.sh" SOLANA_SERVICE="$WORK/root/solana/solana.service"
export SET_POH_SCRIPT="$WORK/root/solana/set_poh_affinity.sh" WAIT_PIN_SCRIPT="$WORK/root/solana/wait_and_pin_poh.sh"
export LOGROTATE_FILE="$WORK/logrotate" POH_PIN_SERVICE="$WORK/poh.service" POH_PIN_TIMER="$WORK/poh.timer"
export MLX5_IRQ_SCRIPT="$WORK/root/solana/mlx5-irq.sh" MLX5_IRQ_SERVICE="$WORK/mlx5.service"
export SOLANA_INSTALL_DIR="$WORK/install" MOSTLY_THRESHOLD_ROOT="$WORK/mct" RESUME_SERVICE_FILE="$WORK/deeploy-resume.service"
export SOLANA_BIN="$WORK/bin" OS_RELEASE_FILE="$WORK/os-release" PROC_CPUINFO="$WORK/cpuinfo" PROC_MEMINFO="$WORK/meminfo" PROC_MDSTAT="$WORK/mdstat"
export SSHD_CONFIG="$WORK/etc/sshd_config" NIC_TUNING_SCRIPT="$WORK/nic-tuning.sh" NIC_TUNING_SERVICE="$WORK/nic-tuning.service"
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
printf '#!/bin/bash\ncase "$1" in catchup) echo "0 slot(s) behind (us:100 them:100)";; *) :;; esac\n' >"$WORK/bin/solana"
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
uname()       { echo x86_64; }
nproc()       { echo 48; }
_cpu_total()  { echo 48; }
_cpu_siblings(){ local c=$1; if (( c<24 )); then echo "$c,$((c+24))"; else echo "$((c-24)),$c"; fi; }
ethtool()     { echo "driver: mlx5_core"; }
ip()          { case "$*" in *"route show default"*) echo "default via 10.0.0.1 dev enp1s0";;
                              *"route get"*) echo "1.1.1.1 dev enp1s0 src 203.0.113.7";; *) echo "enp1s0 UP";; esac; }
lsblk()       { local last=${!#}; case "$*" in *"NAME,SIZE,TYPE,ROTA,MODEL"*) printf '%s\n' "nvme0n1 1920383410176 disk 0 SAMSUNG" "nvme1n1 1920383410176 disk 0 SAMSUNG" "sda 256060514304 disk 0 BOOT";;
                              *"-b -o SIZE"*) echo 1920383410176;; *"-o MODEL"*) echo SAMSUNG;;
                              *"-nr -o MOUNTPOINT"*) case "$last" in */sda) echo "/";; *) echo "";; esac;;
                              *"-nr -o FSTYPE"*) echo "";; *) echo "  (tree)";; esac; }
findmnt()     { echo "/dev/sda2"; }
blkid()       { local d=${!#}; echo "UUID-${d##*/}"; }
mountpoint()  { return 1; }
timedatectl() { echo yes; }
ss()          { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n'; return 0; }   # sshd listening on the new port
df()          { printf 'FS 1G Used Avail Use Mounted\n/dev/x 1800G 10G 1790G 1%% /m\n'; }
ping()        { local h=${!#}; case "$h" in *frankfurt*) printf '%s\n' "0% packet loss" "rtt min/avg/max/mdev = 7/8.0/9/0.3 ms";; *) printf '%s\n' "100% packet loss"; return 1;; esac; }
curl()        { case "$*" in *getGenesisHash*) printf '{"result":"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"}';;
                             *-o*) local i j o; for ((i=1;i<=$#;i++));do [ "${!i}" = -o ]&&{ j=$((i+1)); o="${!j}"; };done; [ -n "${o:-}" ]&&:>"$o";; *) :;; esac; }
# --- mocks: mutations (recorded, never executed) -----------------------------
ALLCALLS="$WORK/allcalls"; : >"$ALLCALLS"
for c in apt-get ufw systemctl blkdiscard mount swapoff umount mdadm cargo rustup setcap getcap update-grub sysctl cp logger sh; do eval "${c}() { echo '${c}' \"\$*\" >>'$CALLS'; echo '${c}' >>'$ALLCALLS'; return 0; }"; done
mkfs.xfs() { echo "mkfs.xfs $*" >>"$CALLS"; echo mkfs.xfs >>"$ALLCALLS"; }
ln()       { case "$*" in */etc/*) echo "ln $*" >>"$CALLS";; *) command ln "$@";; esac; }
require_yes() { return 0; }   # simulate the operator typing 'yes' to the disk wipe
# stub heavy build/network/wait subprocesses (their logic is unit-tested elsewhere)
for s in toolchain_deps toolchain_rust toolchain_anza_cli toolchain_fetch_source toolchain_apply_overlay \
         toolchain_inject_lto_profile toolchain_patch_cargo_script toolchain_compile toolchain_install_release \
         toolchain_write_threshold toolchain_setcap toolchain_verify start_wait_catchup start_pin_poh; do eval "${s}() { :; }"; done
# verify probes: simulate a correctly-isolated, running node
_vf_pid(){ echo 12345; }; _vf_proc_limits(){ printf 'Max open files 2000000 2000000 files\nMax locked memory unlimited unlimited bytes\n'; }
_vf_proc_nice(){ echo -10; }; _vf_oom_score(){ echo -1000; }; _vf_poh_thread(){ echo 999; }; _vf_taskset(){ sget poh_core; }
_vf_isolated(){ sget isolated_set; }; _vf_governor(){ echo performance; }; _vf_thp(){ echo "[never]"; }; _vf_ksm(){ echo 0; }; _vf_numa(){ echo 0; }
_vf_sysctl(){ case "$1" in net.core.rmem_max) echo 134217728;; fs.nr_open) echo 2000000;; esac; }; _vf_catchup(){ echo "0 slot(s) behind"; }; _vf_timer_active(){ echo active; }
# post-reboot isolation read (mock /sys agreeing with the recorded set)
_install_read_isolated(){ sget isolated_set; }; _install_read_cmdline(){ echo "isolcpus=domain,managed_irq,$(sget isolated_set)"; }

# --- config the operator would supply ----------------------------------------
export NODE_NAME=intgbox SSH_PORT=2222 JITO_TAG=v4.0.0-jito DZ_ENABLED=false ASSUME_YES=1
export VOTE_ACCOUNT_PUBKEY=Vote1111111111111111111111111111111111111111

echo "############ FULL-FLOW WALKTHROUGH (phases 0 -> 7, state threading) ############"
for p in 0 1 2 3 4 5 6 7; do
    run_phase "$p" >/dev/null 2>&1
    printf '— after phase %s (%s):\n' "$p" "$(phase_name "$p")"
    case "$p" in
        0) printf '    writes: nic_driver=%s retransmit_supported=%s retransmit_zero_copy=%s data_disk_count=%s\n' \
               "$(sget nic_driver)" "$(sget retransmit_supported)" "$(sget retransmit_zero_copy)" "$(sget data_disk_count)"
           printf '    region: suggested_bam_url=%s\n' "$(sget suggested_bam_url)" ;;
        2) printf '    reads retransmit_supported=%s -> writes poh_core=%s xdp_cores=%s\n' "$(sget retransmit_supported)" "$(sget poh_core)" "$(sget xdp_cores)"
           printf '    isolated_set=%s  irqaffinity=%s  reboot_required=%s\n' "$(sget isolated_set)" "$(sget irqaffinity)" "$(sget reboot_required)" ;;
        3) printf '    writes: solana_home=%s ledger_path=%s accounts_path=%s snapshots_path=%s\n' \
               "$(sget solana_home)" "$(sget ledger_path)" "$(sget accounts_path)" "$(sget snapshots_path)" ;;
        4) printf '    writes: jito_tag=%s\n' "$(sget jito_tag)" ;;
        5) printf '    writes: sync_identity=%s vote_account_pubkey=%s\n' "$(sget sync_identity)" "$(sget vote_account_pubkey)" ;;
        6) printf '    reads poh_core/paths -> generated validator.sh + solana.service + mlx5-irq service\n' ;;
        7) printf '    DZ_ENABLED=false -> skipped\n' ;;
    esac
done

echo ""
echo "############ SEAM ASSERTIONS (each phase reads the prior format) ############"
check "preflight->tuning: nic_driver = mlx5_core"          "$(sget nic_driver)" "mlx5_core"
check "preflight->tuning: retransmit_supported = 1"        "$(sget retransmit_supported)" "1"
check "preflight->validatorcfg: zero_copy = 1"             "$(sget retransmit_zero_copy)" "1"
check "tuning: default POH_CORE propagated = 10"           "$(sget poh_core)" "10"
check "tuning: isolated_set = 1-2,10,25-26,34"             "$(sget isolated_set)" "1-2,10,25-26,34"
check "tuning: xdp_cores = 1-2 (-> RETRANSMIT)"            "$(sget xdp_cores)" "1-2"
check "tuning: reboot_required = 1"                        "$(sget reboot_required)" "1"
check "disk->validatorcfg: ledger_path"                   "$(sget ledger_path)" "$WORK/root/solana/ledger"
check "disk->validatorcfg: accounts_path (separate disk)" "$(sget accounts_path)" "$ACCOUNTS_MOUNT/solana/accounts"
check "disk->validatorcfg: snapshots on LEDGER side"      "$(sget snapshots_path)" "$WORK/root/solana/snapshots"
check "region->validatorcfg: bam_url chosen"              "$(sget bam_url)" "http://frankfurt.mainnet.bam.jito.wtf"
# XFS tuning belongs to Phase 3 (after the FS exists), NOT Phase 2's sysctl.
check "Phase 2 sysctl has NO fs.xfs key"                  "$(grep -c 'fs.xfs' "$SYSCTL_FILE")" "0"
check "Phase 3 wrote the XFS drop-in"                     "$(grep -c 'fs.xfs.xfssyncd_centisecs' "$XFS_SYSCTL_FILE")" "1"

echo ""
echo "############ GENERATED validator.sh threads the chain ############"
check_true "validator.sh generated"                  "[[ -f \"$VALIDATOR_SH\" ]]"
check "POH_CORE (tuning) -> --experimental-poh-pinned-cpu-core" "$(grep -c -- '--experimental-poh-pinned-cpu-core 10' "$VALIDATOR_SH")" "1"
check "RETRANSMIT cpu-cores from xdp_cores (tuning)"           "$(grep -c -- '--experimental-retransmit-xdp-cpu-cores 1-2' "$VALIDATOR_SH")" "1"
check "zero-copy present (mlx5)"                              "$(grep -c -- '--experimental-retransmit-xdp-zero-copy' "$VALIDATOR_SH")" "1"
check "ledger path from disk state"                          "$(grep -c -- "--ledger $WORK/root/solana/ledger" "$VALIDATOR_SH")" "1"
check "accounts path from disk state"                        "$(grep -c -- "--accounts $ACCOUNTS_MOUNT/solana/accounts" "$VALIDATOR_SH")" "1"
check "bam-url from region state"                            "$(grep -c -- '--bam-url http://frankfurt.mainnet.bam.jito.wtf' "$VALIDATOR_SH")" "1"
check "vote-account from keys state"                         "$(grep -c -- '--vote-account Vote1111' "$VALIDATOR_SH")" "1"
check_true "generated validator.sh is valid bash"           "bash -n \"$VALIDATOR_SH\""
check "mlx5-irq service generated (NIC layer)"               "$(grep -c 'Before=solana.service' "$MLX5_IRQ_SERVICE")" "1"

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
check "install recorded deeploy_version in state" "$(sget deeploy_version)" "0.1.0"

echo ""
echo "############ POST-REBOOT RESUME -> verify isolation -> phase 8 ############"
: >"$CALLS"
POST_REBOOT=1 install_run >/dev/null 2>&1; POST_REBOOT=0
check "post-reboot: isolation verified, reboot_done set" "$(state_has reboot_done && echo y || echo n)" "y"
check "post-reboot: phase 8 completed"                   "$(state_has phase-8 && echo y || echo n)" "y"
check "post-reboot: resume service disabled"             "$(grep -c 'systemctl disable deeploy-resume.service' "$CALLS")" "1"

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
( set -Eeuo pipefail; POST_REBOOT=1 install_run ) >/dev/null 2>&1
check "POST_REBOOT install_run survives set -Eeuo pipefail (phase 8)" "$?" "0"
check "phase 8 completed under -e"        "$(state_has phase-8 && echo y || echo n)" "y"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
