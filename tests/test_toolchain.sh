#!/usr/bin/env bash
# Self-contained tests for lib/toolchain.sh — no network, no compiler, no root.
# git/setcap/getcap are mocked; the install dir + overlay dir + threshold paths
# are temp. Focus: the overlay seam, threshold-only-when-applied, LTO inject,
# 5-cap setcap, and keep-previous-release.  NOTE: the threshold value here is a
# PLACEHOLDER — the real one never appears in any repo file.
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never
export SOLANA_INSTALL_DIR="$WORK/install"
export MOSTLY_THRESHOLD_ROOT="$WORK/mct_root"
export JITO_SRC="$WORK/repo"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/toolchain.sh
source "$ROOT/lib/toolchain.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
TFAKE="0.99 1 2 3"          # PLACEHOLDER threshold (not the real value)

GIT_APPLY_CHECK_RC=0
git()    { case "$*" in *"apply --check"*) return "$GIT_APPLY_CHECK_RC";; *) echo "git $*" >>"$CALLS"; return 0;; esac; }
setcap() { echo "setcap $*" >>"$CALLS"; }
getcap() { echo "getcap $*" >>"$CALLS"; }
JITO_TAG="v3.1.14-jito"

echo "== overlay seam: no patch -> vanilla =="
OVERLAY_DIR="$WORK/empty"; mkdir -p "$OVERLAY_DIR"
_OVERLAY_APPLIED=9; : >"$CALLS"
toolchain_apply_overlay >/dev/null 2>&1
check "vanilla: _OVERLAY_APPLIED=0" "$_OVERLAY_APPLIED" "0"
check "vanilla: no git apply"       "$(grep -c 'apply' "$CALLS")" "0"

echo "== overlay seam: patch applies (git apply --check ok) =="
OVERLAY_DIR="$WORK/ov"; mkdir -p "$OVERLAY_DIR"; echo "diff" >"$OVERLAY_DIR/anything.patch"
GIT_APPLY_CHECK_RC=0; _OVERLAY_APPLIED=9; : >"$CALLS"
toolchain_apply_overlay >/dev/null 2>&1
check "applied: _OVERLAY_APPLIED=1" "$_OVERLAY_APPLIED" "1"
check "applied: git apply issued"   "$(grep -c 'git -C .* apply ' "$CALLS")" "1"

echo "== overlay seam: patch does NOT apply (tag drift) -> loud skip, vanilla =="
GIT_APPLY_CHECK_RC=1; _OVERLAY_APPLIED=9; : >"$CALLS"
toolchain_apply_overlay >/dev/null 2>&1
check "drift: _OVERLAY_APPLIED=0" "$_OVERLAY_APPLIED" "0"
check "drift: no git apply"       "$(grep -c 'apply ' "$CALLS")" "0"

echo "== R10: OVERLAY_DIR anchors to the checkout (DEEPLOY_DIR), never the cwd =="
# The old default ("private", cwd-relative) silently built VANILLA when DeePloy
# was invoked from any directory other than the checkout. The default must now
# resolve under DEEPLOY_DIR regardless of $PWD.
mkdir -p "$WORK/checkout/private" "$WORK/elsewhere"
echo "diff" >"$WORK/checkout/private/some.patch"
OVOUT="$(cd "$WORK/elsewhere" && DEEPLOY_DIR="$WORK/checkout" bash -c '
    unset DEEPLOY_OVERLAY_DIR OVERLAY_DIR
    source "'"$ROOT"'/lib/common.sh"
    source "'"$ROOT"'/lib/toolchain.sh"
    printf "%s\n" "$OVERLAY_DIR"
    _toolchain_find_overlay || echo NOTFOUND')"
check "R10: default OVERLAY_DIR = \$DEEPLOY_DIR/private"  "$(sed -n 1p <<<"$OVOUT")" "$WORK/checkout/private"
check "R10: overlay patch found from an unrelated cwd"    "$(sed -n 2p <<<"$OVOUT")" "$WORK/checkout/private/some.patch"
# Explicit DEEPLOY_OVERLAY_DIR still wins over the anchored default.
OVEXP="$(DEEPLOY_DIR="$WORK/checkout" DEEPLOY_OVERLAY_DIR="$WORK/explicit-ov" bash -c '
    unset OVERLAY_DIR
    source "'"$ROOT"'/lib/common.sh"
    source "'"$ROOT"'/lib/toolchain.sh"
    printf "%s" "$OVERLAY_DIR"')"
check "R10: explicit DEEPLOY_OVERLAY_DIR override wins"   "$OVEXP" "$WORK/explicit-ov"

echo "== P13: .gitignore blocks the threshold file anywhere in the tree =="
check "gitignore has **/mostly_confirmed_threshold" "$(grep -cxF '**/mostly_confirmed_threshold' "$ROOT/.gitignore")" "1"
check "gitignore still ignores private/"            "$(grep -cx 'private/' "$ROOT/.gitignore")" "1"

echo "== threshold written ONLY when overlay applied =="
state_set solana_home "$WORK/home"; mkdir -p "$WORK/home"
_OVERLAY_APPLIED=0; rm -f "$MOSTLY_THRESHOLD_ROOT" "$WORK/home/mostly_confirmed_threshold"
toolchain_write_threshold >/dev/null 2>&1
check_false "vanilla: no root threshold file" "[[ -f \"$MOSTLY_THRESHOLD_ROOT\" ]]"
check_false "vanilla: no home threshold file" "[[ -f \"$WORK/home/mostly_confirmed_threshold\" ]]"
OVERLAY_DIR="$WORK/ovt"; mkdir -p "$OVERLAY_DIR"; printf '%s\n' "$TFAKE" >"$OVERLAY_DIR/mostly_confirmed_threshold"
_OVERLAY_APPLIED=1
toolchain_write_threshold >/dev/null 2>&1
check "applied: root threshold written" "$(cat "$MOSTLY_THRESHOLD_ROOT" 2>/dev/null)" "$TFAKE"
check "applied: home threshold written" "$(cat "$WORK/home/mostly_confirmed_threshold" 2>/dev/null)" "$TFAKE"
OVERLAY_DIR="$WORK/ovnone"; mkdir -p "$OVERLAY_DIR"; rm -f "$MOSTLY_THRESHOLD_ROOT"; unset DEEPLOY_MOSTLY_CONFIRMED_THRESHOLD
_OVERLAY_APPLIED=1
toolchain_write_threshold >/dev/null 2>&1
check_false "applied but no value -> not written" "[[ -f \"$MOSTLY_THRESHOLD_ROOT\" ]]"

echo "== LTO profile inject-if-absent =="
C="$WORK/Cargo.toml"; printf '[package]\nname = "jito-solana"\n' >"$C"
toolchain_inject_lto_profile "$C" >/dev/null 2>&1
check "profile injected"      "$(grep -c '\[profile.release-with-lto\]' "$C")" "1"
check "injected at top"       "$(head -1 "$C")" "[profile.release-with-lto]"
check "lto = fat"             "$(grep -c 'lto = \"fat\"' "$C")" "1"
check "codegen-units = 1"     "$(grep -c 'codegen-units = 1' "$C")" "1"
toolchain_inject_lto_profile "$C" >/dev/null 2>&1
check "not duplicated on re-run" "$(grep -c '\[profile.release-with-lto\]' "$C")" "1"

echo "== cargo-install-all.sh --release-with-lto branch =="
S="$WORK/cargo-install-all.sh"
cat >"$S" <<'EOS'
    if [[ $1 = --release-with-debug ]]; then
      buildProfileArg='--profile release-with-debug'
      buildProfile='release-with-debug'
      shift
    fi
EOS
toolchain_patch_cargo_script "$S" >/dev/null 2>&1
check "lto elif inserted"        "$(grep -c 'elif.*--release-with-lto' "$S")" "1"
check "lto profile arg present"  "$(grep -c "buildProfile='release-with-lto'" "$S")" "1"
toolchain_patch_cargo_script "$S" >/dev/null 2>&1
check "elif not duplicated"      "$(grep -c 'elif.*--release-with-lto' "$S")" "1"

echo "== setcap: exactly the 5 caps =="
: >"$CALLS"
toolchain_setcap "/x/agave-validator" >/dev/null 2>&1
check "5-cap setcap" "$(grep -c 'setcap cap_net_raw,cap_net_admin,cap_bpf,cap_perfmon,cap_sys_nice=p /x/agave-validator' "$CALLS")" "1"

echo "== install_release keeps previous release (rollback) =="
mkdir -p "$RELEASES_DIR/v3.1.13-jito/bin"; touch "$RELEASES_DIR/v3.1.13-jito/bin/agave-validator"
ln -sfn "$RELEASES_DIR/v3.1.13-jito" "$ACTIVE_RELEASE"
mkdir -p "$WORK/src/bin"; touch "$WORK/src/bin/agave-validator" "$WORK/src/bin/solana"
JITO_TAG="v3.1.14-jito"
toolchain_install_release "$WORK/src/bin" >/dev/null 2>&1
check "new release bins moved"      "$(find "$RELEASES_DIR/v3.1.14-jito/bin" -type f 2>/dev/null | wc -l | tr -d ' ')" "2"
check "active_release repointed"    "$(readlink "$ACTIVE_RELEASE")" "$RELEASES_DIR/v3.1.14-jito"
check "previous_release recorded"   "$(state_get previous_release)" "$RELEASES_DIR/v3.1.13-jito"
check_true "previous release NOT deleted" "[[ -d \"$RELEASES_DIR/v3.1.13-jito\" ]]"

echo "== build command matches the v4.0.0-jito recipe =="
BUILDCMD=$(DRY_RUN=1 JITO_TAG=v4.0.0-jito RUST_TARGET_CPU=native toolchain_compile 2>&1)
check "has --release-with-lto"        "$(grep -c -- '--release-with-lto' <<<"$BUILDCMD")"          "1"
check "has --no-build-platform-tools" "$(grep -c -- '--no-build-platform-tools' <<<"$BUILDCMD")"   "1"
check "RUSTFLAGS has lld linker arg"  "$(grep -c -- '-Clink-arg=-fuse-ld=lld' <<<"$BUILDCMD")"     "1"
check "RUSTFLAGS has target-cpu"      "$(grep -c -- '-Ctarget-cpu=native' <<<"$BUILDCMD")"         "1"
check "trailing . build context"      "$(grep -c -- 'cargo-install-all.sh .* \.$' <<<"$BUILDCMD")" "1"

echo "== toolchain_rust: file-form rustup install passes ONLY -y to rustup-init =="
# Real-box regression: the installer is downloaded to a FILE then run as
# `sh "$inst" <args>`, so args after the filename go to rustup-init itself.
# The old `sh "$inst" -s -- -y` made rustup-init choke ("unexpected argument '-s'")
# because -s is sh's pipe-form stdin flag. Capture the exact sh invocation.
RUSTLOG="$WORK/rustlog"; : >"$RUSTLOG"
have()    { [[ "$1" == rustup ]] && return 1; command -v "$1" >/dev/null 2>&1; }  # force the install path
curl()    { local o; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { o="$2"; }; shift; done; [[ -n "${o:-}" ]] && printf '#fake rustup-init\n' >"$o"; return 0; }
sh()      { printf 'sh %s\n' "$*" >>"$RUSTLOG"; }                                # record argv, run nothing
rustup()  { echo "rustup $*" >>"$CALLS"; }
HOME="$WORK/fakehome"; mkdir -p "$HOME"
toolchain_rust >/dev/null 2>&1
RUSTCALL=$(grep '^sh ' "$RUSTLOG" | head -1)
check "rustup install passes -y"                 "$(grep -c -- '-y' <<<"$RUSTCALL")"      "1"
check "NO bogus -s flag (the bug)"               "$(grep -c -- ' -s' <<<"$RUSTCALL")"     "0"
check "NO leading -- forwarded to rustup-init"   "$(grep -c -- 'init -- -y\|fake -- ' <<<"$RUSTCALL")" "0"
check "default toolchain set to stable"          "$(grep -c 'rustup default stable' "$CALLS")" "1"
unset -f have curl sh rustup

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
