#!/usr/bin/env bash
# Self-contained tests for lib/upgrade.sh — no network, no build, no validator.
# toolchain functions, identity probes, release API, systemctl are mocked.
# Focus: the live-identity guard (getIdentity, before the build and before every
# restart, --rollback included), no-auto-jump tag selection, toolchain reuse
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
# lines_with <substring> <text> — every line of <text> containing it, whole
lines_with() { local l; while IFS= read -r l; do [[ "$l" == *"$1"* ]] && printf '%s\n' "$l"; done <<<"$2"; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
systemctl() { echo "systemctl $*" >>"$CALLS"; }

echo "== check_releases: default = current tag (no auto-jump to latest) =="
_upgrade_fetch_tags() { case "$1" in *jito-solana*) printf 'v4.2.1-jito\nv4.2.0-jito\nv4.1.2-jito\n';;
                                     *agave*)       printf 'v4.2.1\nv4.2.0\n';; esac; }
state_set jito_tag v4.2.0-jito
upgrade_check_releases >/dev/null 2>&1
check "tag defaults to CURRENT, not latest" "$UPGRADE_TAG" "v4.2.0-jito"

echo "== version floor: refuse to upgrade BELOW the minimum client =="
# An upgrade DOWN to a pre-4.2 client rebuilds fine and then fails to start
# against the validator.sh already on the box (--no-xdp / --poh-pinned-cpu-core).
state_set jito_tag v4.2.1-jito
ask() { REPLY="v4.0.0-jito"; }
UPOUT=$( ( upgrade_check_releases ) 2>&1 ); UPRC=$?
check "below-floor tag -> upgrade aborts"     "$UPRC" "1"
check "message refuses by name"               "$(grep -c 'refusing to upgrade' <<<"$UPOUT")" "1"
check "message names the floor + the flags"    "$(grep -c "only exist from ${DEEPLOY_MIN_JITO_TAG} on" <<<"$UPOUT")" "1"
ask() { REPLY="v4.1.2-jito"; }                # last pre-floor release: also refused
( upgrade_check_releases ) >/dev/null 2>&1
check "4.1.2 -> refused too"                  "$?" "1"
# garbage is refused by the shape check before the floor; the floor's own
# reason is covered in test_common
ask() { REPLY="not-a-tag"; }
UPG=$( ( upgrade_check_releases ) 2>&1 ); UPGRC=$?
check "garbage tag -> aborts"                 "$UPGRC" "1"
check "garbage named as not-a-version-tag"    "$(grep -c 'is not a jito-solana version tag' <<<"$UPG")" "1"
ask() { REPLY="v4.2.1-jito"; }
( upgrade_check_releases ) >/dev/null 2>&1
check "supported tag proceeds"                "$?" "0"

echo "== tag shape: the agave list is for reference; a bare Agave tag is refused =="
# An agave tag such as v4.3.0 can appear in the agave list the picker prints;
# v4.3.0 clears the floor on its numbers and exists in the jito-solana repo
# too. rc8 only warned on it — and warned on v4.3.0-jito.0 as well. The marker
# line is echoed after the call in the same subshell: present means the choice
# stood.
state_set jito_tag v4.2.1-jito
ask() { REPLY="v4.3.0"; }
UPA=$( ( upgrade_check_releases; echo "CHOSEN $UPGRADE_TAG" ) 2>&1 ); UPARC=$?
check "bare Agave v4.3.0 -> upgrade refused"  "$([[ $UPARC -ne 0 ]] && echo refused || echo "rc=$UPARC")" "refused"
check "refusal names the tag and the shape"   "$(grep -cF "'v4.3.0': it is not a jito-solana version tag" <<<"$UPA")" "1"
check "refusal spells out the form"           "$(grep -cF 'vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N]' <<<"$UPA")" "1"
check "refusal: the choice does not stand"    "$(lines_with CHOSEN "$UPA")" ""
ask() { REPLY="v4.3.0-jito.0"; }
UPJ=$( ( upgrade_check_releases; echo "CHOSEN $UPGRADE_TAG" ) 2>&1 ); UPJRC=$?
check "v4.3.0-jito.0 -> proceeds"             "$UPJRC" "0"
check "v4.3.0-jito.0 -> the choice stands"    "$(lines_with CHOSEN "$UPJ")" "CHOSEN v4.3.0-jito.0"
check "v4.3.0-jito.0 -> no warning"           "$(lines_with WARN "$UPJ")" ""
unset -f ask

echo "== R10-1: live-identity guard (getIdentity, fail-closed) =="
# Only system-level seams are mocked — pgrep (is the process up), curl (the
# local RPC) and a solana-keygen stub — so the same cases also run against the
# rc9 guard, which read argv and a staked keypair file. On the box argv is the
# sync identity whatever set-identity did; that guard is red on every case
# below that expects a prompt.
SYNC_PK="SyncPubCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
STAKED_PK="StakedPubAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/solana-keygen" <<EOF
#!/bin/bash
[[ "\$1" == pubkey ]] || exit 1
case "\$2" in *sync-identity*) echo "$SYNC_PK";; *) echo "OtherPubDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD";; esac
EOF
chmod +x "$WORK/bin/solana-keygen"
SOLANA_BIN="$WORK/bin"
: >"$WORK/sync-identity.json"
state_set sync_identity "$WORK/sync-identity.json"
PROC_UP=1
pgrep() { [[ "$PROC_UP" == 1 ]] && echo 4242; }
# One answer per getIdentity call — a pubkey, DOWN or GARBAGE; the last repeats.
RPCQ="$WORK/rpc-queue"
rpc_answers() { printf '%s\n' "$@" >"$RPCQ"; }
curl() {
    [[ "$*" == *getIdentity* ]] || return 7
    local a; a=$(head -1 "$RPCQ")
    if (( $(wc -l <"$RPCQ") > 1 )); then tail -n +2 "$RPCQ" >"$RPCQ.next"; mv "$RPCQ.next" "$RPCQ"; fi
    case "$a" in
        DOWN)    return 7 ;;
        GARBAGE) echo '<html>502 Bad Gateway</html>' ;;
        *)       printf '{"jsonrpc":"2.0","result":{"identity":"%s"},"id":1}\n' "$a" ;;
    esac
}
GATES="$WORK/gates"
require_yes() { echo GATE >>"$GATES"; return "${GATE_RC:-1}"; }
gates() { local n; n=$(wc -l <"$GATES"); echo $((n)); }
reset_case() { : >"$GATES"; : >"$CALLS"; GATE_RC=1; PROC_UP=1; }

reset_case; rpc_answers "$SYNC_PK"
GOUT=$( ( upgrade_identity_guard "before the build" ) 2>&1 ); GRC=$?
check "RPC = sync -> proceeds"                     "$GRC" "0"
check "RPC = sync -> no prompt"                    "$(gates)" "0"
check "RPC = sync -> names the sync identity"      "$(grep -c "on the sync identity ($SYNC_PK" <<<"$GOUT")" "1"

reset_case; rpc_answers "$STAKED_PK"
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "RPC = another pubkey -> prompt"             "$(gates)" "1"
check "RPC = another pubkey, non-interactive -> ABORT" "$GRC" "1"
reset_case; rpc_answers "$STAKED_PK"; GATE_RC=0; STAKED_RESTART=0
upgrade_identity_guard >/dev/null 2>&1; GRC=$?
check "RPC = another pubkey, confirmed -> proceed" "$GRC" "0"
check "... and STAKED_RESTART is flagged"          "$STAKED_RESTART" "1"

reset_case; rpc_answers DOWN
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "RPC down, process up -> prompt"             "$(gates)" "1"
check "RPC down, process up -> ABORT"              "$GRC" "1"

reset_case; rpc_answers GARBAGE
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "process up, identity unparsable -> prompt"  "$(gates)" "1"

# Under DeePloy's ERR trap a non-zero status inside $( ) prints a stray
# "[FAIL] line N" (ERR-NOISE-SUBST); the probes must stay quiet on failure.
reset_case; rpc_answers DOWN; GATE_RC=0
NOISE=$( ( set -E; deeploy_init_traps; trap - EXIT; upgrade_identity_guard ) 2>&1 )
check "RPC down -> no stray [FAIL] line from the ERR trap" "$(grep -cE '\[FAIL\] line [0-9]+' <<<"$NOISE")" "0"

reset_case; PROC_UP=0; rpc_answers DOWN
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "not running (no answer, no process) -> proceed" "$GRC" "0"
check "not running (no answer, no process) -> no prompt" "$(gates)" "0"

# The node's answer decides, not the argv pattern: pgrep is asked only when
# getIdentity is silent.
reset_case; PROC_UP=0; rpc_answers "$STAKED_PK"
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "no process found, RPC = another pubkey -> prompt" "$(gates)" "1"
reset_case; PROC_UP=0; rpc_answers "$SYNC_PK"
( upgrade_identity_guard ) >/dev/null 2>&1; GRC=$?
check "no process found, RPC = sync -> no prompt"  "$(gates)" "0"

# The whole upgrade: sync before the build, another key right before the
# restart. Build and release check are stubbed inside the subshell only.
reset_case; rpc_answers "$SYNC_PK" "$STAKED_PK"
( require_root() { :; }; upgrade_check_releases() { UPGRADE_TAG=v4.3.0-jito.0; }
  upgrade_build() { JITO_TAG="$UPGRADE_TAG"; echo build >>"$CALLS"; }
  upgrade_run ) >/dev/null 2>&1
check "identity changes during the build -> prompt before the restart" "$(gates)" "1"
check "... non-interactive -> no restart"          "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "... the build itself ran"                   "$(grep -c '^build$' "$CALLS")" "1"

# --rollback restarts solana too: same guard, before anything is flipped.
mkdir -p "$WORK/rb/old" "$WORK/rb/new"; ln -sfn "$WORK/rb/new" "$WORK/rb/active"
state_set previous_release "$WORK/rb/old"
reset_case; rpc_answers "$STAKED_PK"
( require_root() { :; }; ACTIVE_RELEASE="$WORK/rb/active" ROLLBACK=1 upgrade_run ) >/dev/null 2>&1
check "--rollback, RPC = another pubkey -> prompt" "$(gates)" "1"
check "... declined -> no restart"                 "$(grep -c 'systemctl restart solana' "$CALLS")" "0"
check "... declined -> active_release untouched"   "$(readlink "$WORK/rb/active")" "$WORK/rb/new"
reset_case; rpc_answers "$SYNC_PK"
( require_root() { :; }; ACTIVE_RELEASE="$WORK/rb/active" ROLLBACK=1 upgrade_run ) >/dev/null 2>&1
check "--rollback, RPC = sync -> no prompt"        "$(gates)" "0"
check "--rollback, RPC = sync -> restarted"        "$(grep -c 'systemctl restart solana' "$CALLS")" "1"
check "--rollback, RPC = sync -> flipped"          "$(readlink "$WORK/rb/active")" "$WORK/rb/old"
state_clear previous_release
PROC_UP=0                     # below: the validator is not running

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

echo "== 7f: _upgrade_fetch_tags — canned GitHub JSON parse; malformed/empty tolerated =="
# Restore the REAL parser (the release-check section mocked it wholesale), then
# drive it with a curl mock returning real-shaped release JSON.
_DEEPLOY_UPGRADE_SOURCED="" source "$ROOT/lib/upgrade.sh"
curl() { printf '[{"tag_name": "v4.0.1-jito", "name": "x"},{"tag_name":"v4.0.0-jito"},{"tag_name":"v3.1.14-jito"}]'; }
check "7f: parses tag_name list from release JSON" "$(_upgrade_fetch_tags jito-foundation/jito-solana | tr '\n' ' ')" "v4.0.1-jito v4.0.0-jito v3.1.14-jito "
curl() { printf 'Not Found'; }                       # GitHub error body, no JSON
OUT7F=$( set -Eeuo pipefail; _upgrade_fetch_tags x/y ); RC7F=$?
check "7f: malformed body -> clean empty, rc0 under -Eeuo" "${RC7F}/${OUT7F}" "0/"
curl() { printf ''; }                                # dead network / empty reply
OUT7F2=$( set -Eeuo pipefail; _upgrade_fetch_tags x/y ); RC7F2=$?
check "7f: empty reply -> clean empty, rc0"                "${RC7F2}/${OUT7F2}" "0/"
# and the tag chooser still defaults to CURRENT when the lists are empty
state_set jito_tag v4.2.0-jito
upgrade_check_releases >/dev/null 2>&1
check "7f: empty tag lists -> chooser defaults to current" "$UPGRADE_TAG" "v4.2.0-jito"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
