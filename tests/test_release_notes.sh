#!/usr/bin/env bash
# The "Compose the release notes" step, extracted from release.yml and RUN.
#
# A release page has to state how much of what it ships has never been on
# hardware, and that figure has to be computed. Asserting that the workflow
# MENTIONS the helper would be a check on text; this runs the step's own script
# against a stubbed helper and watches what it does with each exit code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
WF="$ROOT/.github/workflows/release.yml"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

for t in jq sha256sum; do
    command -v "$t" >/dev/null 2>&1 || {
        printf '  FAIL this suite needs %s and there is none — refusing to skip it\n' "$t"
        printf 'RESULT: %d passed, %d failed\n' "$PASS" "$((FAIL+1))"; exit 1; }
done
[[ -f "$WF" ]] || { printf '  FAIL %s is missing\n' "$WF"
    printf 'RESULT: %d passed, %d failed\n' "$PASS" "$((FAIL+1))"; exit 1; }

# --- extract the step's script ------------------------------------------------
# Bounded at the NEXT step, not at a fixed number of lines: a window that reads
# forward from a match and stops counting is the defect CONTRIBUTING names.
extract_step() {                                  # <step name> -> its run: script
    awk -v want="- name: $1" '
        index($0, want) { instep=1; next }
        instep && /^      - name: / { exit }
        instep && /run: \|/ { inrun=1; next }
        inrun {
            if ($0 !~ /^ *$/ && $0 !~ /^          /) exit
            sub(/^          /, ""); print
        }' "$WF"
}
extract_step "Compose the release notes" > "$WORK/step.sh"

echo "== the extraction took the step, and only the step =="
check "the step's script was found"      "$([[ -s "$WORK/step.sh" ]] && echo yes || echo no)" "yes"
check "  and it is the notes step"       "$(grep -q 'RELEASE_NOTES.md' "$WORK/step.sh" && echo yes || echo no)" "yes"
# Control: the window stopped at the next step rather than running on.
check "  and it stopped before the next step" "$(grep -c 'Create the DRAFT' "$WORK/step.sh")" "0"

# --- a sandbox the step can run in --------------------------------------------
LEDE='DeePloy 0.1.0-rcX
A lede long enough to pass the length floor the step enforces on tag messages.'
mkbox() {                                         # <drift-exit> -> sandbox dir
    # Two statements on purpose: in `local a=$1 b=$a` the expansion of $a runs
    # before a is assigned, so under set -u this function died with "rc: unbound
    # variable" and returned nothing, and without set -u it would have built
    # every sandbox at the same path.
    local rc=$1
    local d="$WORK/box$rc"
    rm -rf "$d"; mkdir -p "$d/bin"
    cp "$WORK/step.sh" "$d/step.sh"
    printf 'boot script\n' > "$d/get-deeploy.sh"
    cat > "$d/hardware-drift.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/drift.argv"
[ "$rc" -eq 0 ] || exit $rc
printf 'DRIFTLINE for %s — 15 files changed, 1233 insertions(+), 144 deletions(-).\n' "\$1"
EOF
    chmod +x "$d/hardware-drift.sh"
    cat > "$d/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *--jq*)      printf '%s\n' '$LEDE' ;;
  *git/ref/tags/*) printf '{"object":{"type":"tag","sha":"deadbeefcafe"}}\n' ;;
  *)           printf '{}\n' ;;
esac
EOF
    chmod +x "$d/bin/gh"
    echo "$d"
}
run_step() {                                      # <sandbox> -> exit code, output in $OUT
    OUT=$(cd "$1" && PATH="$1/bin:$PATH" TAG=v9.9.9-rcX GITHUB_REPOSITORY=o/r \
          bash -e ./step.sh 2>&1); return $?
}

echo "== the helper is called for the tag being built =="
D=$(mkbox 0); run_step "$D"; RC=$?
check "the step succeeds when the helper does"  "$RC" "0"
check "  and it called the helper once"         "$(wc -l < "$D/drift.argv" | tr -d ' ')" "1"
check "  with the tag under build"              "$(cat "$D/drift.argv")" "v9.9.9-rcX"
check "  and the figure reached the notes"      "$(grep -c 'DRIFTLINE for v9.9.9-rcX' "$D/RELEASE_NOTES.md")" "1"
# Position: its own paragraph directly under the lede, not buried in the body.
check "  as its own paragraph under the lede" \
      "$(awk '/^DRIFTLINE/{print NR; exit}' "$D/RELEASE_NOTES.md")" "4"
check "  with a blank line after it" \
      "$(awk 'NR==5 && $0==""{print "blank"}' "$D/RELEASE_NOTES.md")" "blank"

echo "== neither refusal is swallowed =="
# exit 1 (anchor gone) and exit 2 (could not measure) are different answers, and
# CONTRIBUTING keeps them apart — but for a release they mean the same thing:
# no figure, no notes. The step must not treat either as a reason to continue.
for rc in 1 2; do
    D=$(mkbox "$rc"); run_step "$D"; RC=$?
    check "helper exit ${rc} -> the step fails"  "$([[ "$RC" -ne 0 ]] && echo fails || echo continued)" "fails"
    check "  and names the exit code"            "$(grep -c "exited ${rc}" <<<"$OUT")" "1"
    check "  and writes no notes to publish"     "$(grep -c 'DRIFTLINE' "$D/RELEASE_NOTES.md" 2>/dev/null || echo 0)" "0"
done

echo "== the dead Known issue block is gone =="
# It tested for deeploy.sh at mode 100644. tests/test_modes.sh asserts 100755 and
# the gate runs before this step, so the condition could never be true again: a
# guard that cannot fire reads as protection that is not there.
check "release.yml no longer branches on the 100644 mode" \
      "$(grep -c '100644' "$WF")" "0"
check "  and carries no Known-issue heredoc"    "$(grep -c "<<'KNOWN'" "$WF")" "0"
# Control: this search can find such a block — plant one and see it counted.
cp "$WF" "$WORK/planted.yml"
printf "          if [ \"\$(git ls-files -s deeploy.sh | cut -d' ' -f1)\" = \"100644\" ]; then\n" >> "$WORK/planted.yml"
check "  control: the search finds a planted one" "$(grep -c '100644' "$WORK/planted.yml")" "1"
# And the mode it used to test for is not the mode the tree has.
check "  deeploy.sh is 100755 in the index"     "$(cd "$ROOT" && git ls-files -s deeploy.sh | cut -d' ' -f1)" "100755"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
