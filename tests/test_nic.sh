#!/usr/bin/env bash
# Self-contained tests for lib/nic.sh — no NIC, no systemd, no cargo. systemctl/
# git/cargo/setcap are mocked; service/script paths are temp. Covers the mlx5
# IRQ map, bnxt ring/offload tuning, dispatch by driver, and the ZC-test dry-run.
#
# Mocks shadow real commands and are invoked indirectly.
# SC2016: printf'd cargo/env scripts intentionally contain literal $PWD/$PATH.
# SC2030/SC2031: env tweaks inside $(..)/(..) are deliberately subshell-local.
# shellcheck disable=SC2329,SC2016,SC2030,SC2031
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/nic.sh
source "$ROOT/lib/nic.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
require_root() { :; }
systemctl() { echo "systemctl $*" >>"$CALLS"; }
git()       { echo "git $*" >>"$CALLS"; }
cargo()     { echo "cargo $*" >>"$CALLS"; }
setcap()    { echo "setcap $*" >>"$CALLS"; }

state_set solana_home /root/solana
export MLX5_IRQ_SCRIPT="$WORK/mlx5.sh" MLX5_IRQ_SERVICE="$WORK/mlx5.service"
export NIC_TUNING_SCRIPT="$WORK/nic.sh" NIC_TUNING_SERVICE="$WORK/nic.service"

echo "== mlx5 IRQ script (hardcoded PoH=10/XDP=1-2 map) =="
M=$(_nic_render_mlx5_irq_script)
check "comp10 -> cpu11 (off PoH)"     "$(grep -c '10:11' <<<"$M")" "1"
check "comp25-28 -> 7,8,9,12"         "$(grep -c '25:7 26:8 27:9 28:12' <<<"$M")" "1"
check "comp0-4 -> 0-4"                "$(grep -c '0:0 1:1 2:2 3:3 4:4' <<<"$M")" "1"
check "interface via ip route (not hardcoded)" "$(grep -c 'ip route show default' <<<"$M")" "1"
check "no hardcoded enp interface"    "$(grep -c 'enp133' <<<"$M")" "0"
check "writes smp_affinity_list"      "$(grep -c 'smp_affinity_list' <<<"$M")" "1"
check "TODO dynamic note"             "$(grep -ci 'TODO' <<<"$M")" "1"

echo "== mlx5 service =="
MS=$(_nic_render_mlx5_service)
check "Before=solana.service"  "$(grep -c 'Before=solana.service' <<<"$MS")" "1"
check "RemainAfterExit=yes"    "$(grep -c 'RemainAfterExit=yes' <<<"$MS")" "1"
check "ExecStart = script"     "$(grep -c "ExecStart=$WORK/mlx5.sh" <<<"$MS")" "1"

echo "== bnxt ring/offload script =="
B=$(_nic_render_bnxt_script)
check "ring rx 512 tx 512"     "$(grep -c 'rx 512 tx 512' <<<"$B")" "1"
check "offloads off"           "$(grep -c 'gro off lro off gso off tso off' <<<"$B")" "1"
check "interface via ip route" "$(grep -c 'ip route show default' <<<"$B")" "1"

echo "== bnxt service =="
BS=$(_nic_render_bnxt_service)
check "Before=solana.service" "$(grep -c 'Before=solana.service' <<<"$BS")" "1"
check "RemainAfterExit=yes"   "$(grep -c 'RemainAfterExit=yes' <<<"$BS")" "1"

echo "== dispatch: mlx5_core =="
state_set nic_driver mlx5_core; : >"$CALLS"
nic_run >/dev/null 2>&1
check_true  "mlx5 script written"  "[[ -x \"$WORK/mlx5.sh\" ]]"
check_true  "mlx5 service written" "[[ -f \"$WORK/mlx5.service\" ]]"
check "mlx5 service enabled"       "$(grep -c 'systemctl enable mlx5-irq-affinity.service' "$CALLS")" "1"
check_false "no nic-tuning for mlx5" "[[ -f \"$WORK/nic.service\" ]]"

echo "== dispatch: bnxt_en =="
state_set nic_driver bnxt_en; : >"$CALLS"; rm -f "$WORK/nic.sh" "$WORK/nic.service"
nic_bnxt_xdp_test() { return 0; }   # stub the heavy clone/build for the setup test
nic_run >/dev/null 2>&1
check_true "nic-tuning script written"  "[[ -x \"$WORK/nic.sh\" ]]"
check_true "nic-tuning service written" "[[ -f \"$WORK/nic.service\" ]]"
check "nic-tuning enabled"              "$(grep -c 'systemctl enable nic-tuning.service' "$CALLS")" "1"

echo "== dispatch: other driver -> nothing =="
state_set nic_driver r8169; rm -f "$WORK/mlx5.service" "$WORK/nic.service"
nic_run >/dev/null 2>&1
check_false "no mlx5 service" "[[ -f \"$WORK/mlx5.service\" ]]"
check_false "no nic service"  "[[ -f \"$WORK/nic.service\" ]]"

echo "== bnxt ZC test: dry-run does no clone =="
unset -f nic_bnxt_xdp_test
source "$ROOT/lib/nic.sh"   # reload the real function (guard skips, so re-source won't redefine — define directly)
# Re-source is guarded; pull the real function back by clearing the guard.
_DEEPLOY_NIC_SOURCED=""; source "$ROOT/lib/nic.sh"
: >"$CALLS"
DRY_RUN=1 nic_bnxt_xdp_test >/dev/null 2>&1
DRY_RUN=0
check "dry-run: no git clone" "$(grep -c 'git clone' "$CALLS")" "0"

echo "== bnxt ZC test invokes binary with prod CLI (IP + --xdp-interface + --timeout-ms) =="
export XDPCALLS="$WORK/xdpcalls"; : >"$XDPCALLS"
export XDP_COMPAT_SRC="$WORK/xdpsrc"
ip()    { echo "default via 1.1.1.1 dev bnxtnic"; }
cargo() { :; }
git()   { if [[ "$1" == clone ]]; then local d=${!#}; mkdir -p "$d/target/release"
            printf '#!/bin/bash\necho "xdpargs: $*" >> "%s"\nexit 0\n' "$XDPCALLS" >"$d/target/release/xdptest"
            chmod +x "$d/target/release/xdptest"; fi; }
nic_bnxt_xdp_test >/dev/null 2>&1
check "xdp test: '8.8.8.8 --xdp-interface bnxtnic --timeout-ms 1000'" \
    "$(grep -c 'xdpargs: 8.8.8.8 --xdp-interface bnxtnic --timeout-ms 1000' "$XDPCALLS")" "1"

echo "== REGRESSION: nic resolves rustup cargo from ~/.cargo/bin (not on ambient PATH) =="
# The real-box bug: after a fresh rustup install, cargo lives in ~/.cargo/bin,
# which is NOT on the PATH nic.sh inherits -> 'cargo: command not found'. Use a
# REAL on-disk cargo (no cargo() shell mock, which would mask PATH resolution)
# and a CARGO_HOME whose bin is absent from PATH; ensure_cargo_env must find it.
unset -f cargo
CARGO_SBX="$WORK/cargohome"; mkdir -p "$CARGO_SBX/bin"
CARGOLOG="$WORK/cargo.log"; : >"$CARGOLOG"
printf '#!/bin/bash\necho "cargo $*" >> "%s"\nmkdir -p "$PWD/target/release"\nprintf "#!/bin/bash\\necho built >> \\"%s\\"\\nexit 0\\n" > "$PWD/target/release/xdptest"\nchmod +x "$PWD/target/release/xdptest"\n' "$CARGOLOG" "$XDPCALLS" >"$CARGO_SBX/bin/cargo"
chmod +x "$CARGO_SBX/bin/cargo"
printf 'export PATH="%s/bin:$PATH"\n' "$CARGO_SBX" >"$CARGO_SBX/env"
git()    { if [[ "$1" == clone ]]; then local d=${!#}; mkdir -p "$d"; fi; }   # bare clone; cargo makes the binary
setcap() { :; }
export XDP_COMPAT_SRC="$WORK/xdpsrc2"
RC=$( export CARGO_HOME="$CARGO_SBX" PATH="/usr/bin:/bin"      # cargo NOT on PATH initially
      command -v cargo >/dev/null 2>&1 && echo "PRE_FOUND" >&2
      nic_bnxt_xdp_test >/dev/null 2>&1; echo $? )
check "nic ZC test SUCCEEDS once cargo is resolved (rc 0)" "$RC" "0"
check "cargo build --release actually ran"                 "$(grep -c 'cargo build --release' "$CARGOLOG")" "1"

echo "== nic warns cleanly (no crash) when cargo is truly absent =="
git() { if [[ "$1" == clone ]]; then local d=${!#}; mkdir -p "$d"; fi; }
WOUT=$( export CARGO_HOME="$WORK/nocargo_at_all" PATH="/usr/bin:/bin" XDP_COMPAT_SRC="$WORK/xdpsrc3"
        nic_bnxt_xdp_test 2>&1; echo "rc=$?" )
check "absent cargo -> returns 1 (do-not-start)"  "$(grep -c 'rc=1' <<<"$WOUT")" "1"
check "absent cargo -> warns 'cargo not found'"   "$(grep -c 'cargo not found' <<<"$WOUT")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
