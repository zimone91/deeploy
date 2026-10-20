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
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/toolchain.sh
source "$ROOT/lib/toolchain.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }
# lines_with <substring> <text> — every line of <text> containing it, whole
lines_with()  { local l; while IFS= read -r l; do [[ "$l" == *"$1"* ]] && printf '%s\n' "$l"; done <<<"$2"; }

DRY_RUN=0 common_init
CALLS="$WORK/calls"; : >"$CALLS"
TFAKE="0.99 1 2 3"          # PLACEHOLDER threshold (not the real value)

GIT_APPLY_CHECK_RC=0
git()    { case "$*" in *"apply --check"*) return "$GIT_APPLY_CHECK_RC";; *) echo "git $*" >>"$CALLS"; return 0;; esac; }
setcap() { echo "setcap $*" >>"$CALLS"; }
getcap() { echo "getcap $*" >>"$CALLS"; }
JITO_TAG="v3.1.14-jito"

echo "== version floor: refuse to BUILD below the minimum client (phase 4, pre-build) =="
# The whole point of checking here: an old tag builds to the end and only
# then produces a binary that rejects the rendered argv.
state_clear jito_tag
( JITO_TAG=v4.0.0-jito toolchain_resolve_config ) >/dev/null 2>&1
check "4.0.0 -> resolve fails"                 "$?" "1"
check "refusal records NO tag to state"        "$(state_get jito_tag '<none>')" "<none>"
TCOUT=$( ( JITO_TAG=v4.1.2-jito toolchain_resolve_config ) 2>&1 ); TCRC=$?
check "4.1.2 (last pre-floor) -> fails"        "$TCRC" "1"
check "message refuses by name"                "$(grep -c 'refusing to build' <<<"$TCOUT")" "1"
check "message names the floor"                "$(grep -c "$DEEPLOY_MIN_JITO_TAG" <<<"$TCOUT")" "1"
# garbage is refused by the shape check before the floor; the floor's own
# reason is covered in test_common
TCG=$( ( JITO_TAG=latest toolchain_resolve_config ) 2>&1 ); TCGRC=$?
check "garbage tag -> fails (not \${TAG%-jito})" "$TCGRC" "1"
check "garbage named as not-a-version-tag"     "$(grep -c 'is not a jito-solana version tag' <<<"$TCG")" "1"
JITO_TAG=v4.2.0-jito toolchain_resolve_config >/dev/null 2>&1
check "floor tag itself -> ok"                 "$?" "0"
JITO_TAG=v4.2.1-jito toolchain_resolve_config >/dev/null 2>&1
check "supported v4.2.1-jito -> ok"            "$?" "0"
check "accepted tag recorded to state"         "$(state_get jito_tag)" "v4.2.1-jito"
JITO_TAG="v3.1.14-jito"    # restore the suite-wide fixture for the sections below

echo "== tag shape: a -jito.N tag is accepted, a bare Agave tag is refused (phase 4) =="
# rc8 warned on v4.3.0-jito.0 ("does not end in -jito") and only warned on a bare
# Agave v4.3.0, which clears the floor on its numbers. RESOLVED is echoed after
# the call in the same subshell: present means the function ran to its end.
state_clear jito_tag
TSOUT=$( ( JITO_TAG=v4.3.0-jito.0 toolchain_resolve_config; echo RESOLVED ) 2>&1 ); TSRC=$?
check "v4.3.0-jito.0 -> resolve ok"            "$TSRC" "0"
check "v4.3.0-jito.0 -> ran to its end"        "$(lines_with RESOLVED "$TSOUT")" "RESOLVED"
# No shape warning; the one warning left is the recommendation (v4.3.0 < 4.3.2).
check "v4.3.0-jito.0 -> one warning, the recommendation" \
      "$(lines_with WARN "$TSOUT" | grep -c "below the recommended ${DEEPLOY_RECOMMENDED_JITO_TAG:-?}")|$(lines_with WARN "$TSOUT" | wc -l | tr -d ' ')" "1|1"
check "v4.3.0-jito.0 recorded to state"        "$(state_get jito_tag '<none>')" "v4.3.0-jito.0"
state_clear jito_tag
TROUT=$( ( JITO_TAG="${DEEPLOY_RECOMMENDED_JITO_TAG:-v4.3.2-jito}" toolchain_resolve_config; echo RESOLVED ) 2>&1 ); TRRC=$?
check "the recommended tag -> resolves, no warning" "$TRRC|$(lines_with RESOLVED "$TROUT")|$(lines_with WARN "$TROUT")" "0|RESOLVED|"
state_clear jito_tag
TSOUT=$( ( JITO_TAG=v4.3.0 toolchain_resolve_config; echo RESOLVED ) 2>&1 ); TSRC=$?
check "bare Agave v4.3.0 -> resolve fails"     "$([[ $TSRC -ne 0 ]] && echo refused || echo "rc=$TSRC")" "refused"
check "refusal names the tag and the shape"    "$(grep -cF "'v4.3.0': it is not a jito-solana version tag" <<<"$TSOUT")" "1"
check "refusal spells out the form"            "$(grep -cF 'vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N]' <<<"$TSOUT")" "1"
check "refusal stops the run"                  "$(lines_with RESOLVED "$TSOUT")" ""
check "refusal records NO tag to state"        "$(state_get jito_tag '<none>')" "<none>"

echo "== anza CLI: the Anza release is the jito tag's Agave base, never the raw tag =="
# The real function, dry-run (test_integration.sh stubs it). Whole lines, not
# substrings: "anza CLI v4.3.0" is also a prefix of rc8's "anza CLI v4.3.0-jito.0".
ANZA=$( ( DRY_RUN=1 JITO_TAG=v4.3.0-jito.0 toolchain_anza_cli ) 2>&1 ); ANZARC=$?
check "v4.3.0-jito.0 -> rc0"                         "$ANZARC" "0"
check "step line, whole: anza CLI v4.3.0"            "$(lines_with 'install scaffold' "$ANZA")" "━━━ anza CLI v4.3.0 (PATH + install scaffold) ━━━"
check "dry-run line, whole: anza CLI v4.3.0"         "$(lines_with 'would install' "$ANZA")" "  [dry-run] would install anza CLI v4.3.0"
check "the raw tag never reaches the output"         "$(grep -cF 'v4.3.0-jito.0' <<<"$ANZA")" "0"
ANZB=$( ( DRY_RUN=1 JITO_TAG=v4.3.0 toolchain_anza_cli ) 2>&1 ); ANZBRC=$?
check "bare Agave v4.3.0 -> refused (rc != 0)"       "$([[ $ANZBRC -ne 0 ]] && echo refused || echo "rc=$ANZBRC")" "refused"
check "refusal names the tag and the shape"          "$(grep -cF "'v4.3.0': it is not a jito-solana version tag" <<<"$ANZB")" "1"
check "refusal spells out the form"                  "$(grep -cF 'vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N]' <<<"$ANZB")" "1"
check "refusal: no anza CLI step in the output"      "$(grep -cF 'anza CLI' <<<"$ANZB")" "0"
# Past dry-run: the URL curl is handed — on rc8 it named v4.3.0-jito.0, a release
# Anza does not have (404). The stub prints only https arguments; sh runs nothing.
anza_live() {
    ( curl() { local a; for a; do [[ $a == https://* ]] && printf 'CURL %s\n' "$a"; done; }
      sh() { :; }
      DRY_RUN=0 JITO_TAG="$1" toolchain_anza_cli ) 2>&1
}
ANZU=$(anza_live v4.3.0-jito.0)
check "live: curl gets the base's URL, whole line"   "$(lines_with CURL "$ANZU")" "CURL https://release.anza.xyz/v4.3.0/install"
ANZV=$(anza_live v4.3.0)
check "live: bare Agave v4.3.0 -> curl never called" "$(lines_with CURL "$ANZV")" ""
check "live: the shape refusal is why"               "$(grep -cF "'v4.3.0': it is not a jito-solana version tag" <<<"$ANZV")" "1"

echo "== R10-7d: before phase 3 erases anything, the tag the build will use must exist =="
# toolchain_check_tag runs from run_phase 3 while the build is still ahead. Shape
# and floor are the checks above. Existence is asked of the jito-solana repo
# (git ls-remote --exit-code: 0 / 2 / anything else) and of the Anza CLI release
# for the tag's base (HTTP 200 / 404 / anything else; curl prints 000 and exits
# non-zero when nothing answers). Nothing is recorded: phase 4 records the tag.
LSR_RC=0; ANZA_CODE=200; NETLOG="$WORK/net"
tag_check() {                                     # <tag> [stdin] -> output; network calls in NETLOG
    : >"$NETLOG"
    ( git()  { echo "git $* [prompt=${GIT_TERMINAL_PROMPT:-unset}]" >>"$NETLOG"; [[ "$1" == ls-remote ]] && return "$LSR_RC"; return 0; }
      curl() { echo "curl $*" >>"$NETLOG"; printf '%s' "$ANZA_CODE"; [[ "$ANZA_CODE" != 000 ]]; }
      JITO_TAG="$1" toolchain_check_tag; echo "CHECKED rc=$?" ) 2>&1
}
state_set jito_tag untouched
OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: tag and Anza release both there -> checked, rc 0" "$(lines_with CHECKED "$OUT")|$(grep -c 'v4.3.0-jito.0 exists in https://github.com/jito-foundation/jito-solana.git, and so does the Anza CLI release v4.3.0' <<<"$OUT")" "CHECKED rc=0|1"
check "  git asks for exactly that tag, with no terminal prompt" "$(lines_with ls-remote "$(cat "$NETLOG")")" "git ls-remote --exit-code --tags https://github.com/jito-foundation/jito-solana.git refs/tags/v4.3.0-jito.0 [prompt=0]"
check "  curl asks the base's install URL for its HTTP code"     "$(grep -c '^curl .*-w %{http_code} https://release.anza.xyz/v4.3.0/install$' "$NETLOG")" "1"
check "  and nothing is recorded (phase 4 records the tag)"      "$(state_get jito_tag)" "untouched"
LSR_RC=2; OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: no such tag in the repo -> refused as not existing" "$(lines_with CHECKED "$OUT")|$(grep -c 'Refusing: v4.3.0-jito.0 does not exist in https://github.com/jito-foundation/jito-solana.git (no refs/tags/v4.3.0-jito.0)' <<<"$OUT")|$(grep -c '^curl' "$NETLOG")" "|1|0"
LSR_RC=128; OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: the repo does not answer -> refused as unchecked" "$(lines_with CHECKED "$OUT")|$(grep -c 'could not check that v4.3.0-jito.0 exists in https://github.com/jito-foundation/jito-solana.git (git ls-remote exited 128)' <<<"$OUT")|$(grep -c 'does not exist' <<<"$OUT")" "|1|0"
LSR_RC=0; ANZA_CODE=404; OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: Anza has no such release -> refused as not existing" "$(lines_with CHECKED "$OUT")|$(grep -c 'the Anza CLI release v4.3.0, which phase 4 installs for v4.3.0-jito.0, does not exist (https://release.anza.xyz/v4.3.0/install answered 404)' <<<"$OUT")" "|1"
ANZA_CODE=000; OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: Anza does not answer (000) -> refused as unchecked" "$(lines_with CHECKED "$OUT")|$(grep -c 'could not check the Anza CLI release v4.3.0 for v4.3.0-jito.0 (https://release.anza.xyz/v4.3.0/install answered 000)' <<<"$OUT")|$(grep -c 'does not exist' <<<"$OUT")" "|1|0"
ANZA_CODE=503; OUT=$(tag_check v4.3.0-jito.0)
check "R10-7d: Anza answers 503 -> refused as unchecked" "$(lines_with CHECKED "$OUT")|$(grep -c 'answered 503)' <<<"$OUT")" "|1"
ANZA_CODE=200
OUT=$(tag_check v4.3.0)
check "R10-7d: a bare Agave tag -> refused by shape, no network asked" "$(lines_with CHECKED "$OUT")|$(grep -cF "'v4.3.0': it is not a jito-solana version tag" <<<"$OUT")|$(wc -l <"$NETLOG" | tr -d ' ')" "|1|0"
OUT=$(tag_check v4.1.2-jito)
check "R10-7d: below the floor -> refused, no network asked" "$(lines_with CHECKED "$OUT")|$(grep -c "$DEEPLOY_MIN_JITO_TAG" <<<"$OUT")|$(wc -l <"$NETLOG" | tr -d ' ')" "|1|0"
OUT=$(tag_check "")
check "R10-7d: no tag and no terminal -> refused, no network asked" "$(lines_with CHECKED "$OUT")|$(grep -c 'no value and no default for: jito-solana build tag' <<<"$OUT")|$(wc -l <"$NETLOG" | tr -d ' ')" "|1|0"
OUT=$(printf 'v4.3.0-jito.0\n' | { NONINTERACTIVE=0; tag_check ""; })
check "R10-7d: no tag -> asked; the answer is the tag checked" "$(lines_with CHECKED "$OUT")|$(grep -c 'jito-solana build tag' <<<"$OUT")|$(grep -c 'refs/tags/v4.3.0-jito.0' "$NETLOG")|$(state_get jito_tag)" "CHECKED rc=0|1|1|untouched"
# A bare Enter builds the pin; without a terminal the refusal above stands.
# ${…:-}: without the constant (the old tree) these fail instead of set -u
# killing the file.
OUT=$(printf '\n' | { NONINTERACTIVE=0; tag_check ""; })
check "no tag, bare Enter -> the pin is the tag checked" "$(lines_with CHECKED "$OUT")|$(grep -cF "[${DEEPLOY_PIN_JITO_TAG:-<no pin>}]:" <<<"$OUT")|$(grep -cF "refs/tags/${DEEPLOY_PIN_JITO_TAG:-<no pin>}" "$NETLOG")" "CHECKED rc=0|1|1"
state_clear jito_tag
# The prompt ends without a newline, so RESOLVED goes on a line of its own.
OUT=$(printf '\n' | { NONINTERACTIVE=0; unset JITO_TAG; toolchain_resolve_config; printf '\nRESOLVED\n'; } 2>&1)
check "phase 4: no tag, bare Enter -> the pin, recorded" "$(lines_with RESOLVED "$OUT")|$(state_get jito_tag '<none>')" "RESOLVED|${DEEPLOY_PIN_JITO_TAG:-<no pin>}"
# curl's status sits inside $( ): under the production traps the refusal comes out alone.
ANZA_CODE=000
OUT=$( ( git() { return 0; }; curl() { printf 000; return 7; }
         set -Eeuo pipefail; deeploy_init_traps; JITO_TAG=v4.3.0-jito.0 toolchain_check_tag ) 2>&1 ); RC=$?
check "R10-7d: under the production traps the refusal comes out alone" "$RC|$(grep -cE 'line [0-9]+:' <<<"$OUT")|$(grep -c 'could not check the Anza CLI release' <<<"$OUT")" "1|0|1"
ANZA_CODE=200; state_clear jito_tag

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

echo "== overlay seam: patch present but does NOT apply -> HARD STOP (was: silent vanilla) =="
# "No overlay" and "an overlay that does not apply" are different facts. The
# second means the operator deliberately placed a patch and would otherwise get
# a binary without it — the N6 shape (present but unverifiable -> refuse).
GIT_APPLY_CHECK_RC=1; _OVERLAY_APPLIED=9; : >"$CALLS"
DRIFT=$( ( toolchain_apply_overlay ) 2>&1 ); DRIFTRC=$?
check "drift: aborts (rc1)"           "$DRIFTRC" "1"
check "drift: no git apply issued"    "$(grep -c 'apply ' "$CALLS")" "0"
check "drift: names the patch file"   "$(grep -c "$OVERLAY_DIR/anything.patch" <<<"$DRIFT")" "1"
check "drift: names the tag"          "$(grep -c "$JITO_TAG" <<<"$DRIFT")" "1"
check "drift: offers update-the-patch" "$(grep -c 'update the patch' <<<"$DRIFT")" "1"
check "drift: offers build-vanilla-on-purpose" "$(grep -c 'build vanilla on purpose' <<<"$DRIFT")" "1"
# the threshold must NOT be written on the aborted path (it is overlay-gated)
check "drift: _OVERLAY_APPLIED not set to 1" "$([[ "$_OVERLAY_APPLIED" == "1" ]] && echo y || echo n)" "n"
# ...while a genuinely ABSENT overlay stays a silent, supported vanilla build
OVERLAY_DIR="$WORK/empty"
GIT_APPLY_CHECK_RC=1; _OVERLAY_APPLIED=9; : >"$CALLS"
toolchain_apply_overlay >/dev/null 2>&1
check "absent overlay: still rc0 (public path)" "$?" "0"
check "absent overlay: _OVERLAY_APPLIED=0"      "$_OVERLAY_APPLIED" "0"
OVERLAY_DIR="$WORK/ov"   # restore the populated dir for the sections below

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

echo "== build guards degenerate to no-ops against the UPSTREAM 4.2 structure =="
# Both guards were written for 4.0.0, where neither the profile nor the flag
# existed upstream. On 4.2.x upstream ships BOTH — the root Cargo.toml carries
# [profile.release-with-lto] with the same three keys we inject, and
# cargo-install-all.sh already has the --release-with-lto branch. The guards are
# kept for older tags, so what needs proving is that where upstream ships both
# they change NOTHING: a byte-identical file, not merely "no duplicate section".
# Fixtures mirror the 4.2.1 shape (profile order and the arg-parse chain).
U="$WORK/upstream42_Cargo.toml"
cat >"$U" <<'EOT'
[workspace]
resolver = "2"

[profile.release-with-debug]
inherits = "release"
debug = true

[profile.release]
split-debuginfo = "unpacked"
lto = "thin"

[profile.release-with-lto]
inherits = "release"
lto = "fat"
codegen-units = 1
EOT
cp "$U" "$U.pristine"
toolchain_inject_lto_profile "$U" >/dev/null 2>&1
check "upstream Cargo.toml: inject returns 0"        "$?" "0"
check_true "upstream Cargo.toml: BYTE-IDENTICAL"     "cmp -s \"$U\" \"$U.pristine\""
check "upstream Cargo.toml: still ONE lto profile"   "$(grep -c '^\[profile.release-with-lto\]$' "$U")" "1"
check "upstream Cargo.toml: head untouched"          "$(head -1 "$U")" "[workspace]"

US="$WORK/upstream42_cargo-install-all.sh"
cat >"$US" <<'EOT'
    elif [[ $1 = --release-with-debug ]]; then
      buildProfileArg='--profile release-with-debug'
      buildProfile='release-with-debug'
      shift
    elif [[ $1 = --release-with-lto ]]; then
      buildProfileArg='--profile release-with-lto'
      buildProfile='release-with-lto'
      shift
    elif [[ $1 = --no-build-platform-tools ]]; then
      noBuildPlatformTools=true
      shift
    fi
EOT
cp "$US" "$US.pristine"
toolchain_patch_cargo_script "$US" >/dev/null 2>&1
check "upstream script: patch returns 0"             "$?" "0"
check_true "upstream script: BYTE-IDENTICAL"         "cmp -s \"$US\" \"$US.pristine\""
check "upstream script: still ONE lto branch"        "$(grep -c 'elif.*--release-with-lto' "$US")" "1"
check "upstream script: platform-tools branch intact" "$(grep -c 'no-build-platform-tools' "$US")" "1"
# and the flags DeePloy passes are the ones this structure accepts
for flag in "${TOOLCHAIN_BUILD_FLAGS[@]}"; do
    check "upstream script accepts ${flag}"          "$(grep -c -- "\$1 = ${flag} \]\]" "$US")" "1"
done

echo "== setcap: exactly the 5 caps =="
: >"$CALLS"
toolchain_setcap "/x/agave-validator" >/dev/null 2>&1
check "5-cap setcap" "$(grep -c 'setcap cap_net_raw,cap_net_admin,cap_bpf,cap_perfmon,cap_sys_nice=p /x/agave-validator' "$CALLS")" "1"
# PROBE-RC-ZERO: no active_release yet (a dry-run on a fresh box), so readlink -f
# fails inside the default of $1. Under the production traps the WARN comes out
# alone, with no stray "[FAIL] line N".
: >"$CALLS"
OUT=$( ( set -Eeuo pipefail; deeploy_init_traps; trap - EXIT; ACTIVE_RELEASE="$WORK/no-release" toolchain_setcap ) 2>&1 ); RC=$?
check "PROBE-RC-ZERO: no active_release, under the production traps -> the WARN alone" \
      "$RC|$(grep -cE '\[FAIL\] line [0-9]+:' <<<"$OUT")|$(grep -c 'agave-validator not found for setcap' <<<"$OUT")|$(grep -c setcap "$CALLS")" "0|0|1|0"

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
