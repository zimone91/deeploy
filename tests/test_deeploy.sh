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

echo "== version: --version flag output =="
check "print_version prints 'DeePloy <ver>'" "$(print_version)" "DeePloy $DEEPLOY_VERSION"

echo "== full run (no reboot needed): all phases, then re-run skips done =="
reset_state; ONLY_PHASE=""; FORCE=0; POST_REBOOT=0; DZ_ENABLED=false
: >"$RAN"; install_run >/dev/null 2>&1
check "install records deeploy_version at start" "$(state_get deeploy_version)" "$DEEPLOY_VERSION"
check "phase fns ran (0-6 incl nic, +start; DZ off)" "$(wc -l <"$RAN" | tr -d ' ')" "9"
check "start_run ran"  "$(grep -c '^start_run$' "$RAN")" "1"
: >"$RAN"; install_run >/dev/null 2>&1
check "re-run: all phases skipped (idempotent)" "$(wc -l <"$RAN" | tr -d ' ')" "0"

echo "== --only runs exactly one phase =="
reset_state; : >"$RAN"; ONLY_PHASE=4 install_run >/dev/null 2>&1; ONLY_PHASE=""
check "only phase 4 ran" "$(cat "$RAN")" "toolchain_build"

echo "== I2: install --only 8 is isolation-gated (it bypasses the reboot boundary) =="
# --only 8 runs start_run directly, skipping _install_reboot_boundary. The gate now
# lives in start_run, so a mismatch must still refuse to start. Use a start_run that
# runs the REAL gate (the suite's stub doesn't), then restore the stub.
reset_state; state_set isolated_set "1-2,10,25-26,34"
start_run() { _install_verify_isolation || fail "iso gate"; echo 'start_run' >>"$RAN"; }
_install_read_isolated() { echo "10,34"; }                          # MISMATCH (GRUB didn't apply)
_install_read_cmdline()  { echo "isolcpus=domain,managed_irq,10,34"; }
: >"$RAN"; ( ONLY_PHASE=8 install_run ) >/dev/null 2>&1; RC=$?
check "I2: --only 8 mismatch -> aborts"        "$RC" "1"
check "I2: --only 8 mismatch -> start NOT run" "$(grep -c '^start_run$' "$RAN")" "0"
_install_read_isolated() { echo "1-2,10,25-26,34"; }               # MATCH
: >"$RAN"; ONLY_PHASE=8 install_run >/dev/null 2>&1; ONLY_PHASE=""
check "I2: --only 8 match -> start runs"        "$(grep -c '^start_run$' "$RAN")" "1"
start_run() { echo 'start_run' >>"$RAN"; }   # restore the suite stub

echo "== DZ Phase 7 dispatch: runs doublezero_run (pointer) iff state dz_enabled=true =="
# The enable DECISION is made EARLY in Phase 1 (base -> dz_should_enable), which
# is stubbed here; Phase 7 dispatch reads state dz_enabled. So simulate Phase 1's
# recorded decision and assert Phase 7 honors it.
reset_state; : >"$RAN"; state_set dz_enabled true;  install_run >/dev/null 2>&1
check "state dz_enabled=true: doublezero_run (pointer) ran" "$(grep -c '^doublezero_run$' "$RAN")" "1"
reset_state; : >"$RAN"; state_set dz_enabled false; install_run >/dev/null 2>&1
check "state dz_enabled=false: skipped"          "$(grep -c '^doublezero_run$' "$RAN")" "0"
reset_state; : >"$RAN"; install_run >/dev/null 2>&1   # unset -> default skip
check "no dz_enabled recorded: skipped"          "$(grep -c '^doublezero_run$' "$RAN")" "0"

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
# systemd starts with an empty env; without these, Phase 8's catchup wait runs
# '/.local/.../solana' (empty $HOME) and cargo isn't on PATH. (env-class fix)
check "resume sets HOME=/root"                 "$(grep -c 'Environment=\"HOME=/root\"' "$RESUME_SERVICE_FILE")" "1"
check "resume sets PATH incl /root/.cargo/bin" "$(grep -c 'Environment=\"PATH=.*/root/.cargo/bin\"' "$RESUME_SERVICE_FILE")" "1"
check "resume service enabled"                 "$(grep -c 'systemctl enable deeploy-resume.service' "$CALLS")" "1"
check "reboot_pending recorded"                "$(state_has reboot_pending && echo y || echo n)" "y"
check "systemctl reboot issued (confirm Y)"    "$(grep -c 'systemctl reboot' "$CALLS")" "1"

echo "== old-server reminder before the reboot gate (dz_enabled only) =="
# Pre-reboot branch calls dz_print_old_server_reminder when dz_enabled. Stub it
# to observe; gated on state so DZ-off runs never see it.
dz_print_old_server_reminder() { echo 'dz_old_server_reminder' >>"$RAN"; }
reset_state; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"; state_set dz_enabled true
: >"$RAN"; : >"$CALLS"; install_run >/dev/null 2>&1
check "DZ on: old-server reminder before gate" "$(grep -c '^dz_old_server_reminder$' "$RAN")" "1"
reset_state; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"; state_set dz_enabled false
: >"$RAN"; install_run >/dev/null 2>&1
check "DZ off: no old-server reminder"          "$(grep -c '^dz_old_server_reminder$' "$RAN")" "0"
unset -f dz_print_old_server_reminder

echo "== POST-REBOOT, isolation MATCHES: verify -> start -> self-disable =="
reset_state; mark_07_done; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
_install_read_isolated() { echo "1-2,10,25-26,34"; }
_install_read_cmdline()  { echo "ro quiet isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34"; }
: >"$RAN"; : >"$CALLS"
POST_REBOOT=1 install_run >/dev/null 2>&1; POST_REBOOT=0
check "post-reboot: start_run ran"            "$(grep -c '^start_run$' "$RAN")" "1"
check "post-reboot: reboot_done set"          "$(state_has reboot_done && echo y || echo n)" "y"
check "post-reboot: resume service disabled"  "$(grep -c 'systemctl disable deeploy-resume.service' "$CALLS")" "1"

echo "== POST-REBOOT DZ: gated on dz_CONNECTED (not dz_enabled) — verify/restore only after dz-connect =="
# The boundary calls dz_resume only if dz_connected is set (a tunnel exists). DZ
# prepared-but-not-connected (the normal pre-swap state) must NOT trigger resume.
dz_resume() { echo 'dz_resume' >>"$RAN"; }            # observe the resume call
# Connected pre-reboot -> resume verifies/restores, does NOT re-run the prepare flow.
reset_state; mark_07_done; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
state_set dz_enabled true; state_set dz_connected "$(date +%s 2>/dev/null || echo t)"
: >"$RAN"; : >"$CALLS"
POST_REBOOT=1 install_run >/dev/null 2>&1; POST_REBOOT=0
check "post-reboot dz_connected: dz_resume called" "$(grep -c '^dz_resume$' "$RAN")" "1"
check "post-reboot dz_connected: doublezero_run NOT re-run" "$(grep -c '^doublezero_run$' "$RAN")" "0"
check "post-reboot dz_connected: still started"    "$(grep -c '^start_run$' "$RAN")" "1"
# Prepared but NOT connected (dz_enabled=true, dz_connected unset) -> NO resume.
dz_resume() { echo 'dz_resume' >>"$RAN"; }
reset_state; mark_07_done; state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
state_set dz_enabled true     # prepared, but dz-connect hasn't run -> dz_connected unset
: >"$RAN"
POST_REBOOT=1 install_run >/dev/null 2>&1; POST_REBOOT=0
check "post-reboot prepared-not-connected: dz_resume NOT called" "$(grep -c '^dz_resume$' "$RAN")" "0"
unset -f dz_resume

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

echo "== I5: manual --resume after the reboot already happened -> verify + Phase 8 (no 2nd reboot) =="
# The resume service died before recording reboot_done; the operator runs a manual
# 'install --resume' (POST_REBOOT=0). The booted cmdline already carries the wanted
# isolation, so the boundary detects that, verifies, and proceeds — it must NOT
# re-prompt a second pointless reboot.
reset_state; mark_07_done
state_set reboot_required 1; state_set isolated_set "1-2,10,25-26,34"
state_set reboot_pending "earlier-ts"            # a reboot WAS armed; the box rebooted
_install_read_isolated() { echo "1-2,10,25-26,34"; }                            # isolation is live
_install_read_cmdline()  { echo "isolcpus=domain,managed_irq,1-2,10,25-26,34 nohz_full=1-2,10,25-26,34"; }
: >"$RAN"; : >"$CALLS"
POST_REBOOT=0 install_run >/dev/null 2>&1
check "I5: proceeded to Phase 8 (start_run ran)" "$(grep -c '^start_run$' "$RAN")" "1"
check "I5: reboot_done now latched"              "$(state_has reboot_done && echo y || echo n)" "y"
check "I5: NO second reboot issued"              "$(grep -c 'systemctl reboot' "$CALLS")" "0"
check_false "I5: did NOT (re)write a resume service" "[[ -f \"$RESUME_SERVICE_FILE\" ]]"

echo "== R1: a degraded (non-zero) start_run does NOT mark phase 8 done =="
# start_run returns non-zero when the node never synced (catchup failed). Under
# set -e that aborts run_phase before phase_end, so phase 8 stays un-done and an
# idempotent resume re-attempts it instead of skipping a node that never synced.
reset_state; clear_phase 8
start_run() { echo 'start_run' >>"$RAN"; return 1; }   # simulate a degraded finish
: >"$RAN"
( set -Eeuo pipefail; ONLY_PHASE=8 install_run ) >/dev/null 2>&1; RC=$?; ONLY_PHASE=""
check "R1: degraded start_run -> install exits non-zero" "$RC" "1"
check "R1: degraded start_run actually ran"              "$(grep -c '^start_run$' "$RAN")" "1"
check "R1: phase 8 NOT marked done"                      "$(is_phase_done 8 && echo y || echo n)" "n"
start_run() { echo 'start_run' >>"$RAN"; }   # restore the suite stub

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
