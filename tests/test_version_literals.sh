#!/usr/bin/env bash
# Every version literal a stranger can act on agrees with DEEPLOY_VERSION.
#
# The same comparison exists in ci.yml and release.yml, but both live in steps
# guarded by `if: github.ref_type == 'tag'`. That puts the check AFTER the
# irreversible move: by the time it can fail, the tag is pushed, the release is
# not built, and the command on the README's first screen answers 404. This
# repository has spent two releases moving checks to before the point of no
# return; a version bump has one too, and this is it. The tag-time step stays —
# it also compares against the TAG, which cannot be known here.
#
# SCANNED, because a reader copies these and they must point at this version:
#   README.md          the install commands on the front page
#   get-deeploy.sh     the pinned default AND the usage examples in its header
#   worker/index.mjs   the default the bare zim.one/deeploy path serves
# NOT SCANNED, because they are history or fixtures and must keep their old
# values — a bump that rewrote them would be destroying the record:
#   CHANGELOG.md                 every past release names its own version
#   hardware-drift.sh            its header cites the rc7 notes as the reason
#                                the helper exists
#   tests/test_hardware_drift.sh its fixture tag must be a tag that EXISTS
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

SCANNED=(README.md get-deeploy.sh worker/index.mjs)

src_version() {                                   # <tree> -> 0.1.0-rcN
    # shellcheck disable=SC2016  # the literal ${DEEPLOY_VERSION:-...} IS what is
    # being matched in another file; expanding it here would search for its value.
    sed -n 's/^DEEPLOY_VERSION="\${DEEPLOY_VERSION:-\([^}]*\)}"$/\1/p' "$1/lib/common.sh"
}
literals() {                                      # <tree> -> sorted unique vX.Y.Z... set
    local t=$1 f
    for f in "${SCANNED[@]}"; do
        [[ -f "$t/$f" ]] && LC_ALL=C grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[-0-9A-Za-z.]*' "$t/$f"
    done | LC_ALL=C sort -u
}
# The worker default is what the bare path SERVES, so it is read by running the
# module. A grep over the declaration reports the first quoted literal and is
# blind to anything after it: `const DEFAULT_TAG = 'v0.1.0-rc6'.replace(...)`
# would read as agreeing while the endpoint served something else.
worker_default() {                                # <tree> -> the served tag
    (cd "$1" && node --input-type=module -e '
        globalThis.fetch = async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) });
        const m = await import("./worker/index.mjs");
        const r = await m.default.fetch(new Request("https://zim.one/deeploy"));
        if (r.status !== 200) { process.exit(1); }
        process.stdout.write(r.headers.get("x-deeploy-tag") || "");
    ' 2>/dev/null)
}
gate() {                                          # <tree> -> 0 + summary, or 1 + reason
    local t=$1 ver set w
    ver=$(src_version "$t")
    [[ -n "$ver" ]] || { echo "could not parse DEEPLOY_VERSION out of lib/common.sh"; return 1; }
    set=$(literals "$t")
    [[ -n "$set" ]] || { echo "no version literal found in any scanned file — the derivation broke, not the files"; return 1; }
    if [[ "$set" != "v${ver}" ]]; then
        printf 'scanned files carry [%s]; lib/common.sh says [v%s]\n' "$(printf '%s' "$set" | tr '\n' ' ')" "$ver"
        return 1
    fi
    w=$(worker_default "$t")
    [[ -n "$w" ]] || { echo "could not determine the worker default by running worker/index.mjs"; return 1; }
    if [[ "$w" != "v${ver}" ]]; then
        printf 'the worker serves [%s]; lib/common.sh says [v%s]\n' "$w" "v${ver}"
        return 1
    fi
    printf '%s files carry one literal, v%s, and the worker serves it\n' "${#SCANNED[@]}" "$ver"
    return 0
}

echo "== the tree as it stands =="
OUT=$(gate "$ROOT"); RC=$?
check "every scanned literal agrees with DEEPLOY_VERSION" "$RC" "0"
check "  and it says what it compared"                    "$(grep -c 'the worker serves it' <<<"$OUT")" "1"
# A set of one is the whole point, so prove the set was actually built.
check "  control: literals were found at all"             "$([[ -n "$(literals "$ROOT")" ]] && echo found || echo none)" "found"
check "  control: the worker answered"                    "$(worker_default "$ROOT")" "v$(src_version "$ROOT")"

echo "== a stale literal anywhere must go red =="
craft() {                                         # <name> -> a copy of the tree
    local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"
    (cd "$ROOT" && git ls-files -z) | (cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$d"
    echo "$d"
}
VER=$(src_version "$ROOT")
control() {                                       # <desc> <tree> <expected substring>
    local out rc
    out=$(gate "$2" 2>&1); rc=$?
    check "$1 -> refused"           "$rc" "1"
    check "  for the stated reason" "$(grep -c "$3" <<<"$out")" "1"
}

D=$(craft readme)
# perl, not `sed '0,/re/s//../'`: that address is a GNU extension and BSD sed
# accepts it, matches nothing and exits 0, so a fallback after `||` never runs.
perl -0pi -e "s/v\Q${VER}\E/v0.0.1-old/" "$D/README.md"
check "control: the plant landed in README"  "$(grep -c 'v0.0.1-old' "$D/README.md")" "1"
control "a stale literal in README" "$D" "lib/common.sh says"

# A COMMENT, not code: the header of get-deeploy.sh shows the command a reader
# copies before they ever run anything, so a stale one there is the same defect.
D=$(craft comment)
perl -0pi -e "s/#   sh -c \"\\\$\(curl -sSfL https:\/\/zim\.one\/deeploy\/v\Q${VER}\E\)\"/#   sh -c \"\\\$(curl -sSfL https:\/\/zim.one\/deeploy\/v0.0.1-old)\"/" "$D/get-deeploy.sh"
check "control: the plant landed in a COMMENT" \
      "$(grep -c '^#.*v0\.0\.1-old' "$D/get-deeploy.sh")" "1"
check "  and the code default is untouched" \
      "$(grep -c "TAG=\"\${DEEPLOY_INSTALL_TAG:-v${VER}}\"" "$D/get-deeploy.sh")" "1"
control "a stale literal in a comment" "$D" "lib/common.sh says"

D=$(craft worker)
perl -0pi -e "s/export const DEFAULT_TAG = 'v\Q${VER}\E'/export const DEFAULT_TAG = 'v0.0.1-old'/" "$D/worker/index.mjs"
check "control: the plant landed in the worker" "$(grep -c "DEFAULT_TAG = 'v0.0.1-old'" "$D/worker/index.mjs")" "1"
control "a stale worker default" "$D" "lib/common.sh says"

# The worker is read by RUNNING it, so a declaration that parses as current but
# serves something else must still be caught. This is the case a grep cannot see.
D=$(craft worker_runtime)
perl -0pi -e "s/export const DEFAULT_TAG = 'v\Q${VER}\E'/export const DEFAULT_TAG = 'v${VER}'.replace('rc','xx')/" "$D/worker/index.mjs"
check "control: the literal in the declaration is still the current one" \
      "$(grep -c "DEFAULT_TAG = 'v${VER}'\." "$D/worker/index.mjs")" "1"
control "a worker that serves something else" "$D" "the worker serves"

D=$(craft noversion)
perl -0pi -e "s/^DEEPLOY_VERSION=.*$/DEEPLOY_VERSION=\"broken\"/m" "$D/lib/common.sh"
control "DEEPLOY_VERSION cannot be parsed" "$D" "could not parse DEEPLOY_VERSION"

echo "== history is not scanned, and that is deliberate =="
# If these were scanned, every bump would have to rewrite the changelog and the
# fixtures, which is the opposite of what they are for.
check "CHANGELOG names older versions"       "$(LC_ALL=C grep -cE 'v?0\.1\.0-rc[1-6]' "$ROOT/CHANGELOG.md" | awk '{print ($1>0)?1:0}')" "1"
check "  and the gate is green anyway"       "$RC" "0"
check "the drift helper cites rc7 in prose"  "$(grep -c 'rc7' "$ROOT/hardware-drift.sh")" "1"
check "  and it is not in the scanned set"   "$(printf '%s\n' "${SCANNED[@]}" | grep -c '^hardware-drift.sh$')" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
