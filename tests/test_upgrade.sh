#!/usr/bin/env bash
# Self-contained tests for lib/upgrade.sh — no network, no build, no validator.
# toolchain functions, identity probes, release API, systemctl are mocked.
# Focus: the STAKED-identity guard, no-auto-jump tag selection, toolchain reuse
# (no flag drift), and rollback (one symlink flip).
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329,SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/toolchain.sh
source "$ROOT/lib/toolchain.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/upgrade.sh
source "$ROOT/lib/upgrade.sh"

PASS=0; FAIL=0
check()      { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true() { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
systemctl() { echo "systemctl $*" >>"$CALLS"; }

echo "== check_releases: default = current tag (no auto-jump to latest) =="
_upgrade_fetch_tags() { case "$1" in *jito-solana*) printf 'v4.0.1-jito\nv4.0.0-jito\nv3.1.14-jito\n';;
                                     *agave*)       printf 'v4.0.1\nv4.0.0\n';; esac; }
state_set jito_tag v4.0.0-jito
upgrade_check_releases >/dev/null 2>&1
check "tag defaults to CURRENT, not latest" "$UPGRADE_TAG" "v4.0.0-jito"

echo "== STAKED-identity guard =="
# Staked + non-interactive: require_yes refuses -> ABORT (no restart of a staked node).
_upgrade_running_identity() { echo "StakedPubAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; }
_upgrade_staked_pubkey()    { echo "StakedPubAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; }
( upgrade_identity_guard ) >/dev/null 2>&1
check "staked + non-interactive -> ABORT" "$?" "1"
# Staked + explicit yes: proceeds and flags STAKED_RESTART.
require_yes() { return 0; }
STAKED_RESTART=0
upgrade_identity_guard >/dev/null 2>&1
check "staked + confirmed -> proceed" "$?" "0"
check "STAKED_RESTART flagged"        "$STAKED_RESTART" "1"
# Unstaked running -> proceed.
_upgrade_running_identity() { echo "FakePubBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"; }
upgrade_identity_guard >/dev/null 2>&1
check "unstaked running -> proceed" "$?" "0"
# Not running -> proceed.
_upgrade_running_identity() { echo ""; }
upgrade_identity_guard >/dev/null 2>&1
check "not running -> proceed" "$?" "0"

echo "== upgrade_build reuses the toolchain (identical recipe, no drift) =="
BUILDLOG="$WORK/build"; : >"$BUILDLOG"
for f in toolchain_fetch_source toolchain_apply_overlay toolchain_inject_lto_profile \
         toolchain_patch_cargo_script toolchain_compile toolchain_install_release \
         toolchain_write_threshold toolchain_setcap toolchain_verify; do
    eval "${f}() { echo '${f}' >>'$BUILDLOG'; }"
done
UPGRADE_TAG=v4.0.1-jito upgrade_build >/dev/null 2>&1
check "fetch source"        "$(grep -c toolchain_fetch_source "$BUILDLOG")" "1"
check "overlay-aware"       "$(grep -c toolchain_apply_overlay "$BUILDLOG")" "1"
check "compile (pinned flags)" "$(grep -c toolchain_compile "$BUILDLOG")" "1"
check "install_release (keeps previous)" "$(grep -c toolchain_install_release "$BUILDLOG")" "1"
check "5-cap setcap"        "$(grep -c toolchain_setcap "$BUILDLOG")" "1"
check "threshold (overlay-gated)" "$(grep -c toolchain_write_threshold "$BUILDLOG")" "1"
CL=$(grep -n toolchain_compile "$BUILDLOG" | cut -d: -f1)
IL=$(grep -n toolchain_install_release "$BUILDLOG" | cut -d: -f1)
check_true "compile BEFORE install_release" "[[ $CL -lt $IL ]]"
check "jito_tag updated in state" "$(state_get jito_tag)" "v4.0.1-jito"

echo "== rollback: one symlink flip + restart =="
export ACTIVE_RELEASE="$WORK/active"
mkdir -p "$WORK/releases/v3.1.14-jito" "$WORK/releases/v4.0.1-jito"
ln -sfn "$WORK/releases/v4.0.1-jito" "$ACTIVE_RELEASE"
state_set previous_release "$WORK/releases/v3.1.14-jito"
: >"$CALLS"
upgrade_rollback >/dev/null 2>&1
check "active_release flipped to previous" "$(readlink "$ACTIVE_RELEASE")" "$WORK/releases/v3.1.14-jito"
check "restart issued"                     "$(grep -c 'systemctl restart solana' "$CALLS")" "1"
state_clear previous_release
( upgrade_rollback ) >/dev/null 2>&1
check "no previous release -> rollback fails" "$?" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
