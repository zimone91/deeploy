#!/usr/bin/env bash
# Tests for deeploy.sh dispatch + reboot-resume. The reboot itself can't be
# mocked, but the state transitions and the non-interactive guarantee can:
# phase functions are replaced with a run-log, the isolation read is overridden,
# systemctl is mocked, and the resume-service path is sandboxed.
#
# Mocks shadow real commands; dispatch-control globals (ONLY_PHASE/FORCE/
# POST_REBOOT/DZ_ENABLED) are consumed by the sourced install_run.
# shellcheck disable=SC2329,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
export RESUME_SERVICE_FILE="$WORK/deeploy-resume.service"
export DEEPLOY_CONF="$WORK/none.conf"   # no config to load

# Sourcing deeploy.sh defines functions (main runs only when executed).
# shellcheck source-path=SCRIPTDIR source=../deeploy.sh
source "$ROOT/deeploy.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
RAN="$WORK/ran"; CALLS="$WORK/calls"; : >"$RAN"; : >"$CALLS"

require_root() { :; }
systemctl()    { echo "systemctl $*" >>"$CALLS"; return 0; }
# Replace phase functions with a run-log.
for f in preflight_run base_run tuning_run disk_run toolchain_build keys_run \
         validatorcfg_run nic_run doublezero_run start_run; do
    eval "${f}() { echo '${f}' >>'$RAN'; }"
done

reset_state() { rm -rf "${DEEPLOY_STATE_DIR:?}/state.d" "$RESUME_SERVICE_FILE"; mkdir -p "$DEEPLOY_STATE_DIR/state.d"; }
mark_07_done() { local i; for i in 0 1 2 3 4 5 6 7; do mark_phase_done "$i"; done; }

echo "== full run (no reboot needed): all phases, then re-run skips done =="
reset_state; ONLY_PHASE=""; FORCE=0; POST_REBOOT=0; DZ_ENABLED=false
: >"$RAN"; install_run >/dev/null 2>&1
check "phase fns ran (0-6 incl nic, +start; DZ off)" "$(wc -l <"$RAN" | tr -d ' ')" "9"
check "start_run ran"  "$(grep -c '^start_run$' "$RAN")" "1"
: >"$RAN"; install_run >/dev/null 2>&1
check "re-run: all phases skipped (idempotent)" "$(wc -l <"$RAN" | tr -d ' ')" "0"

echo "== --only runs exactly one phase =="
reset_state; : >"$RAN"; ONLY_PHASE=4 install_run >/dev/null 2>&1; ONLY_PHASE=""
check "only phase 4 ran" "$(cat "$RAN")" "toolchain_build"

echo "== DZ phase gated on DZ_ENABLED =="
reset_state; : >"$RAN"; DZ_ENABLED=true install_run >/dev/null 2>&1
check "DZ on: doublezero_run ran" "$(grep -c '^doublezero_run$' "$RAN")" "1"
reset_state; : >"$RAN"; DZ_ENABLED=false install_run >/dev/null 2>&1
check "DZ off: doublezero_run skipped" "$(grep -c '^doublezero_run$' "$RAN")" "0"

echo "== REBOOT GATE (pre-reboot): installs oneshot, stops before phase 8 =="
reset_state; DZ_ENABLED=false
state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
: >"$RAN"; : >"$CALLS"
install_run >/dev/null 2>&1
check "phase 8 (start) NOT run before reboot" "$(grep -c '^start_run$' "$RAN")" "0"
check "phases 0-7 ran"                         "$(grep -c '^keys_run$' "$RAN")" "1"
check_true "resume service written"            "[[ -f \"$RESUME_SERVICE_FILE\" ]]"
check "resume ExecStart = install --resume --post-reboot" "$(grep -c 'ExecStart=.*install --resume --post-reboot' "$RESUME_SERVICE_FILE")" "1"
check "resume WantedBy=multi-user.target"      "$(grep -c 'WantedBy=multi-user.target' "$RESUME_SERVICE_FILE")" "1"
check "resume service enabled"                 "$(grep -c 'systemctl enable deeploy-resume.service' "$CALLS")" "1"
check "reboot_pending recorded"                "$(state_has reboot_pending && echo y || echo n)" "y"
check "systemctl reboot issued (confirm Y)"    "$(grep -c 'systemctl reboot' "$CALLS")" "1"

echo "== POST-REBOOT, isolation MATCHES: verify -> start -> self-disable =="
reset_state; mark_07_done; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
_install_read_isolated() { echo "1-2,10,25-26,34"; }
_install_read_cmdline()  { echo "ro quiet isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34"; }
: >"$RAN"; : >"$CALLS"
POST_REBOOT=1 install_run >/dev/null 2>&1; POST_REBOOT=0
check "post-reboot: start_run ran"            "$(grep -c '^start_run$' "$RAN")" "1"
check "post-reboot: reboot_done set"          "$(state_has reboot_done && echo y || echo n)" "y"
check "post-reboot: resume service disabled"  "$(grep -c 'systemctl disable deeploy-resume.service' "$CALLS")" "1"

echo "== POST-REBOOT, isolation MISMATCH: FAIL + diagnostics, validator NOT started =="
reset_state; mark_07_done; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
_install_read_isolated() { echo "10,34"; }   # GRUB didn't fully apply
_install_read_cmdline()  { echo "ro quiet isolcpus=domain,managed_irq,10,34"; }
: >"$RAN"
DIAG=$( ( POST_REBOOT=1 install_run ) 2>&1 ); RC=$?
check "mismatch: install exits non-zero" "$RC" "1"
check "mismatch: start_run NOT called"   "$(grep -c '^start_run$' "$RAN")" "0"
check "mismatch: reboot_done NOT set"     "$(state_has reboot_done && echo y || echo n)" "n"
check "diag: expected set shown"          "$(grep -c 'expected isolated set : 1-2,10,25-26,34' <<<"$DIAG")" "1"
check "diag: actual set shown"            "$(grep -c 'actual   isolated set : 10,34' <<<"$DIAG")" "1"
check "diag: concrete fix (--only 2)"     "$(grep -c 'install --only 2' <<<"$DIAG")" "1"

echo "== isolation mismatch: retry counter escalates, clears on match =="
reset_state; state_set isolated_set "1-2,10,25-26,34"
_install_read_isolated() { echo "10,34"; }
D=""; for _ in 1 2 3; do D=$( ( _install_verify_isolation ) 2>&1 || true ); done
check "escalation on 3rd boot" "$(grep -c 'attempt #3' <<<"$D")" "1"
check "mismatch count = 3"     "$(state_get isolation_mismatch_count)" "3"
_install_read_isolated() { echo "1-2,10,25-26,34"; }
_install_read_cmdline()  { echo "isolcpus=domain,managed_irq,1-2,10,25-26,34"; }
_install_verify_isolation >/dev/null 2>&1
check "counter cleared on match" "$(state_get isolation_mismatch_count 0)" "0"

echo "== POST-REBOOT never runs an un-done interactive phase =="
reset_state   # nothing done
: >"$RAN"
( POST_REBOOT=1 install_run ) >/dev/null 2>&1
check "post-reboot + un-done phase 0 -> fail" "$?" "1"
check "no phase ran"                          "$(wc -l <"$RAN" | tr -d ' ')" "0"

echo "== no reboot needed -> phase 8 runs directly, no resume service =="
reset_state; : >"$RAN"; : >"$CALLS"
install_run >/dev/null 2>&1
check "start_run ran (no gate)"         "$(grep -c '^start_run$' "$RAN")" "1"
check_false "no resume service written" "[[ -f \"$RESUME_SERVICE_FILE\" ]]"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
