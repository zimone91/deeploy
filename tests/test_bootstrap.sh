#!/usr/bin/env bash
# Self-contained tests for get-deeploy.sh — no network.
#
# The other suites mock by shadowing commands with shell functions, because they
# test modules that are sourced into the same shell. get-deeploy.sh is a
# separate /bin/sh process, and a function does not cross a process boundary.
# So the mocks here are executable stubs on a PATH that contains ONLY what a
# scenario is supposed to have: dropping curl from that PATH is how "curl is
# missing" is tested, and dropping both hash tools is how "no way to verify" is.
#
# Every stub appends to one call log, and the fixture tarball carries its own
# deeploy.sh that logs if it is ever executed. That turns the boundary this
# script must not cross into a fact about a file instead of a claim in a
# comment: after every scenario, the log must not mention deeploy.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BOOTSTRAP="$ROOT/get-deeploy.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"
    else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

TAG="v9.9.9-test"
CALLS="$WORK/calls"

# --- the release the fake curl serves -----------------------------------------
# A real tar.gz with a real digest: only the manifest is under test control, so
# the checksum path exercises the actual hash tool rather than a stubbed answer.
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/deeploy-${TAG}/lib"
cat > "$FIXTURE/deeploy-${TAG}/deeploy.sh" <<'EOS'
#!/usr/bin/env bash
# If the bootstrap ever executes the deployer, this line is the evidence.
printf 'FIXTURE-DEPLOY-RAN %s\n' "$*" >> "${DEEPLOY_TEST_CALLS:?}"
EOS
chmod +x "$FIXTURE/deeploy-${TAG}/deeploy.sh"
echo "# lib" > "$FIXTURE/deeploy-${TAG}/lib/common.sh"
( cd "$FIXTURE" && tar -czf "$WORK/release.tar.gz" "deeploy-${TAG}" )
GOOD_SUM="$(shasum -a 256 "$WORK/release.tar.gz" | cut -d' ' -f1)"

# --- sandbox PATH -------------------------------------------------------------
# mkbin <dir> <tool>...  — symlink the named REAL tools, then add the stubs.
mkbin() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local t p
    for t in "$@"; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$dir/$t"; done

    cat > "$dir/curl" <<EOS
#!/bin/sh
printf 'curl %s\n' "\$*" >> "$CALLS"
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -*) shift ;;
        *)  url="\$1"; shift ;;
    esac
done
case "\$url" in
    *SHA256SUMS)  cp "$WORK/served/SHA256SUMS" "\$out" ;;
    *.tar.gz)     cp "$WORK/release.tar.gz" "\$out" ;;
    *)            exit 22 ;;
esac
EOS
    cat > "$dir/sudo" <<EOS
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "$CALLS"
exit 0
EOS
    cat > "$dir/chown" <<EOS
#!/bin/sh
printf 'chown %s\n' "\$*" >> "$CALLS"
exit 0
EOS
    cat > "$dir/chmod" <<EOS
#!/bin/sh
printf 'chmod %s\n' "\$*" >> "$CALLS"
exit 0
EOS
    cat > "$dir/id" <<EOS
#!/bin/sh
printf '501\n'
EOS
    # A deeploy.sh anywhere on PATH is a second tripwire, independent of the
    # one inside the tarball.
    cat > "$dir/deeploy.sh" <<EOS
#!/bin/sh
printf 'PATH-DEPLOY-RAN %s\n' "\$*" >> "$CALLS"
EOS
    chmod +x "$dir"/curl "$dir"/sudo "$dir"/chown "$dir"/chmod "$dir"/id "$dir"/deeploy.sh
}

# run <name> <bin-dir> [env=val ...] — run the bootstrap in a fresh cwd.
RUN_OUT=""; RUN_RC=0; RUN_DIR=""
run() {
    local name="$1" bindir="$2"; shift 2
    RUN_DIR="$WORK/run-$name"; mkdir -p "$RUN_DIR"
    RUN_OUT="$(cd "$RUN_DIR" && env -i \
        PATH="$bindir" HOME="$RUN_DIR" DEEPLOY_TEST_CALLS="$CALLS" \
        DEEPLOY_INSTALL_TAG="$TAG" "$@" sh "$BOOTSTRAP" 2>&1)"
    RUN_RC=$?
    return 0
}

serve_sum() { mkdir -p "$WORK/served"; printf '%s  deeploy-%s.tar.gz\n' "$1" "$TAG" > "$WORK/served/SHA256SUMS"; }

# A sandbox PATH must carry everything the tools under test FORK, not just the
# tools themselves. gzip is here because `tar -xzf` is not one process on every
# platform: GNU tar (ubuntu-24.04, where CI runs) execs an external gzip, while
# BSD tar (macOS) decompresses in-process with libz. Omitting it passes locally
# and fails in CI with `tar (child): gzip: Cannot exec`. It goes on all three
# PATHs, including the ones whose scenario dies before tar: which tool a
# scenario happens to reach must not be what decides whether its PATH is sound.
FULL="$WORK/bin-full"; mkbin "$FULL" sh cp mktemp awk cut rm tar gzip shasum sha256sum
NOCURL="$WORK/bin-nocurl"; mkbin "$NOCURL" sh cp mktemp awk cut rm tar gzip shasum sha256sum; rm -f "$NOCURL/curl"
NOHASH="$WORK/bin-nohash"; mkbin "$NOHASH" sh cp mktemp awk cut rm tar gzip

: > "$CALLS"

echo "== happy path: checksum matches -> unpacked, handed to root, next command printed =="
serve_sum "$GOOD_SUM"
run happy "$FULL"
check "exits 0"                             "$RUN_RC" "0"
check_true "unpacked into ./deeploy-<tag>"  "[[ -d '$WORK/run-happy/deeploy-$TAG' ]]"
check_true "the deployer is present"        "[[ -x '$WORK/run-happy/deeploy-$TAG/deeploy.sh' ]]"
check "reports the verified digest"         "$(grep -c "checksum ok  $GOOD_SUM" <<<"$RUN_OUT")" "1"
check "ownership handed over"               "$(grep -c 'chown -R root:root' "$CALLS")" "1"
check "group/world write removed"           "$(grep -c 'chmod -R go-w' "$CALLS")" "1"
check "prints the dry-run as the next step" "$(grep -c 'deeploy.sh install --dry-run' <<<"$RUN_OUT")" "1"
check "says nothing was deployed"           "$(grep -c 'Nothing has been deployed' <<<"$RUN_OUT")" "1"

echo "== checksum mismatch -> refuses, and leaves no directory behind =="
serve_sum "0000000000000000000000000000000000000000000000000000000000000000"
run mismatch "$FULL"
check_false "does not exit 0"                    "[[ '$RUN_RC' == '0' ]]"
check "says checksum mismatch"                   "$(grep -c 'checksum mismatch' <<<"$RUN_OUT")" "1"
check_false "no deeploy-<tag>/ left behind"      "[[ -e '$WORK/run-mismatch/deeploy-$TAG' ]]"
check "says nothing was unpacked"                "$(grep -c 'nothing was unpacked' <<<"$RUN_OUT")" "1"

echo "== SHA256SUMS has no entry for our tarball -> refuses (not 'assume ok') =="
mkdir -p "$WORK/served"; printf '%s  some-other-file.tar.gz\n' "$GOOD_SUM" > "$WORK/served/SHA256SUMS"
run noentry "$FULL"
check_false "does not exit 0"               "[[ '$RUN_RC' == '0' ]]"
check "names the missing entry"             "$(grep -c 'no entry for' <<<"$RUN_OUT")" "1"
check_false "nothing unpacked"              "[[ -e '$WORK/run-noentry/deeploy-$TAG' ]]"

echo "== neither sha256sum nor shasum -> refuses instead of skipping verification =="
serve_sum "$GOOD_SUM"
run nohash "$NOHASH"
check_false "does not exit 0"                   "[[ '$RUN_RC' == '0' ]]"
check "refuses without a hash tool"             "$(grep -c 'refusing to install without verifying' <<<"$RUN_OUT")" "1"
check_false "nothing unpacked"                  "[[ -e '$WORK/run-nohash/deeploy-$TAG' ]]"

echo "== the target directory already exists -> stops without overwriting =="
serve_sum "$GOOD_SUM"
mkdir -p "$WORK/run-exists/deeploy-$TAG"; echo "mine" > "$WORK/run-exists/deeploy-$TAG/keep-me"
run exists "$FULL"
check_false "does not exit 0"               "[[ '$RUN_RC' == '0' ]]"
check "says it will not overwrite"          "$(grep -c 'will not overwrite' <<<"$RUN_OUT")" "1"
check "the existing content is untouched"   "$(cat "$WORK/run-exists/deeploy-$TAG/keep-me")" "mine"

echo "== curl missing -> a clear refusal, not a silent wget fallback =="
run nocurl "$NOCURL"
check_false "does not exit 0"               "[[ '$RUN_RC' == '0' ]]"
check "names curl"                          "$(grep -c 'curl is required' <<<"$RUN_OUT")" "1"

echo "== the tag is validated in the script, not only in the route =="
serve_sum "$GOOD_SUM"
# The values below are payloads, not expressions: they must reach the script as
# the literal text an attacker would supply, so single quotes are the point.
# shellcheck disable=SC2016
for bad in 'v1;whoami' 'v1 x' '$(id)' 'main' 'v1$(whoami)' 'v1`id`'; do
    RUN_DIR="$WORK/run-bad"; rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
    out="$(cd "$RUN_DIR" && env -i PATH="$FULL" HOME="$RUN_DIR" DEEPLOY_TEST_CALLS="$CALLS" \
        DEEPLOY_INSTALL_TAG="$bad" sh "$BOOTSTRAP" 2>&1)"; rc=$?
    check_false "rejects DEEPLOY_INSTALL_TAG='$bad'" "[[ '$rc' == '0' ]]"
    check_false "and downloads nothing for it"       "[[ -e '$RUN_DIR/deeploy-$bad' ]]"
    # Without this, a non-zero exit from anything at all would pass the two
    # checks above: the refusal has to come from the tag validator itself.
    check "and the refusal names the variable"       "$(grep -c 'DEEPLOY_INSTALL_TAG' <<<"$out")" "1"
done

echo "== THE BOUNDARY: deeploy.sh was never executed, in any scenario above =="
check "fixture deployer never ran"  "$(grep -c 'FIXTURE-DEPLOY-RAN' "$CALLS")" "0"
check "no deeploy.sh found on PATH ran" "$(grep -c 'PATH-DEPLOY-RAN' "$CALLS")" "0"
check "the call log mentions deeploy.sh nowhere" "$(grep -c 'deeploy\.sh' "$CALLS")" "0"
# The tripwires must be capable of firing, or the three checks above prove nothing.
"$FULL/deeploy.sh" selftest
DEEPLOY_TEST_CALLS="$CALLS" "$FIXTURE/deeploy-$TAG/deeploy.sh" selftest
check "control: the PATH tripwire does fire when invoked"    "$(grep -c 'PATH-DEPLOY-RAN' "$CALLS")" "1"
check "control: the fixture tripwire does fire when invoked" "$(grep -c 'FIXTURE-DEPLOY-RAN' "$CALLS")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
