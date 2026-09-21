#!/usr/bin/env bash
# In-page links must point at headings that exist.
#
# The class has bitten this repository once already, in a different shape: six
# docs/ links in the README resolved in the working tree and were dead inside the
# release tarball, because git archive packs tracked files only. This is the same
# failure one level down — a link to an anchor on the same page, after the
# heading it names has been deleted.
#
# The specific reason it was written: the commit after it removed the "Known issue
# in v0.1.0-rc6" section, and the README linked to that anchor near the top.
# Nothing else would have caught the link left behind — the version gate matches
# v0.1.0-rc6 and the anchor spells it v010-rc6, with the dots gone. It did go red
# against that removal, which is what the gate was for. The link is gone with the
# section, so this tree now has none, and the self-test below is what makes that
# zero a measurement rather than a broken parser's silence.
#
# HOW GITHUB BUILDS AN ANCHOR — and how much of it this knows.
#
# Measured on 2026-09-21 against the RENDERED README at github.com/zimone91/
# deeploy (branch main), which is the only point where any of this touches
# reality:
#   heading:  "Known issue in v0.1.0-rc6"
#   id present in the DOM:  user-content-known-issue-in-v010-rc6
#   id NOT present:         known-issue-in-v010-rc6
#   link in the page:       #known-issue-in-v010-rc6
#   following the link scrolled 0 -> 2763 and put the heading in view
#
# Two things follow, and the second is not obvious until you see both forms. The
# user-content- prefix lives ONLY in the DOM; it is not in the link. Anything
# computing anchors must produce the UNPREFIXED form, or every link in the tree
# looks broken. And "the id exists" and "the link works" are separate claims that
# were measured separately.
#
# The subset confirmed by that one heading, and all this implements: lowercase,
# spaces become hyphens, punctuation is dropped, an existing hyphen is kept.
# v0.1.0-rc6 -> v010-rc6.
#
# ONE HEADING IS ONE HEADING. Headings carrying anything outside that subset —
# non-ASCII letters, emoji, inline code spans, links inside the heading text,
# runs of spaces, leading or trailing punctuation — are NOT covered. GitHub does
# more than this; what is written here is what was checked.
#
# SCOPE: links inside this repository only. External URLs are deliberately not
# followed: that needs the network, the network flaps, and a gate that flaps
# teaches people to ignore it.
#
# CHANGELOG.md IS included here, unlike Gate A in test_modes.sh. There the
# changelog is excluded because it records what was true at a past release and
# holding it to the present tree would make history unwritable. An anchor link is
# different: it is dead wherever it lives, and a reader clicking it now gets
# nothing. Measured on 2026-09-21, CHANGELOG.md contains zero anchor links, so
# this costs nothing today. If one ever appears and points at a heading a later
# commit removes, the collision with "never edit the changelog" is a decision to
# take then, with the case in front of you — not one to pre-empt here.
#
# SIBLING: .github/workflows/ci.yml carries "README links files the tarball will
# actually carry", which checks that linked docs/ FILES are tracked. That one
# answers whether the file ships; this one answers whether the anchor exists.
# Two related gates in two places is fine as long as each names the other.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKDIR=$(mktemp -d); trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

# The covered subset, and nothing more. LC_ALL=C so the case fold is the ASCII
# one on every box: a UTF-8 locale would fold letters this does not claim to
# handle, which would be the gate quietly widening its own coverage.
slug() {
    LC_ALL=C printf '%s' "$1" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

md_files() {                                      # <root>
    if git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
    then git -C "$1" ls-files '*.md'
    else ( cd "$1" && find . -name '*.md' -type f | sed 's|^\./||' ); fi
}

# Headings, as anchors. Lines inside fenced code blocks are skipped: a shell
# comment in a ``` block looks exactly like a heading. Measured on 2026-09-21
# this tree has zero such lines, so today it changes nothing — it is here so a
# future code block cannot silently satisfy a link that points nowhere.
anchors_of() {                                    # <file>
    local fence=0 line
    while IFS= read -r line; do
        case "$line" in '```'*) fence=$((1 - fence)); continue ;; esac
        (( fence )) && continue
        case "$line" in '#'*)
            [[ "$line" =~ ^#{1,6}[[:space:]]+(.*)$ ]] || continue
            slug "${BASH_REMATCH[1]}"; echo ;;
        esac
    done < "$1"
}

# Links of the form ](...#anchor). http(s) targets are dropped by design.
links_of() {                                      # <file> -> "target-path<TAB>anchor"
    local t a
    grep -oE '\]\([^)]*#[^)]+\)' "$1" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' \
    | while IFS= read -r t; do
        case "$t" in http*) continue ;; esac
        a="${t#*#}"; t="${t%%#*}"
        printf '%s\t%s\n' "$t" "$a"
    done
}

# Prove the derivation works before believing what it returns. A tree can
# legitimately hold no anchor links — this one does — and "found none" then has to
# be a measurement, not the silence of a parser that stopped working. Refusing on
# a count of zero was the first shape of this, and it would have failed the tree
# for having nothing wrong with it. So the machinery runs first against a fixture
# whose answer is known, and only then against the tree.
_anchors_self_test() {                            # -> 0 if links_of/anchors_of work
    local d got; d=$(mktemp -d)
    printf '# Title\n\nSee [it](#a-known-heading).\n\n## A known heading\n' >"$d/SELF.md"
    got=$(links_of "$d/SELF.md")
    if [[ "$got" != $'\ta-known-heading' ]]; then
        rm -rf "$d"; echo "self-test: links_of returned [${got}], expected a same-file link to a-known-heading"; return 1
    fi
    if ! anchors_of "$d/SELF.md" | grep -qxF 'a-known-heading'; then
        rm -rf "$d"; echo "self-test: anchors_of did not turn '## A known heading' into its anchor"; return 1
    fi
    rm -rf "$d"; return 0
}

gate_anchors() {                                  # <root> -> 0 + summary, or 1 + reason
    local root="$1" f line t a target have n=0 dead=""
    _anchors_self_test || return 1
    while IFS= read -r f; do
        # Split the line by hand. `IFS=$'\t' read -r t a` looks equivalent and is
        # not: a tab is IFS whitespace, so a leading one is stripped and a
        # same-file link (empty target) silently shifts the anchor into $t. That
        # made the derivation count zero links and report the docs as the problem.
        while IFS= read -r line; do
            t="${line%%$'\t'*}"; a="${line#*$'\t'}"
            [[ -n "$a" ]] || continue
            n=$((n + 1))
            if [[ -z "$t" ]]; then target="$f"
            else target=$(cd "$root/$(dirname "$f")" 2>/dev/null && printf '%s' "${PWD#"$root"/}/$t"); target="${target#/}"; fi
            [[ -f "$root/$target" ]] || { dead="$dead ${f}#${a}(no ${target})"; continue; }
            # Collected first, not piped: `| grep -q` exits on the first match and
            # the producer takes SIGPIPE, which under pipefail turns a successful
            # lookup into a write error on stderr.
            have=$(anchors_of "$root/$target")
            grep -qxF -- "$a" <<<"$have" || dead="$dead ${f}->${target}#${a}"
        done < <(links_of "$root/$f")
    done < <(md_files "$root")

    [[ -z "$dead" ]] || { echo "links whose anchor does not exist:${dead}"; return 1; }
    if (( n == 0 )); then
        echo "derivation verified on a fixture; this tree holds no anchor links"
    else
        echo "${n} in-repository anchor link(s) checked, all resolve"
    fi
    return 0
}

echo "== anchors: every in-page link points at a heading that exists =="
OUT=$(gate_anchors "$ROOT"); RC=$?
check "gate passes on this tree"            "$RC" "0"
check "  and it says the derivation was verified" \
      "$(grep -c 'derivation verified on a fixture' <<<"$OUT")" "1"

# The self-test is the thing standing between "no links" and "no parser". Assert
# it works, and assert it can FAIL — a self-test that always passes is the same
# defect it exists to prevent.
_anchors_self_test >/dev/null 2>&1
check "the derivation self-test passes"     "$?" "0"
( links_of() { :; }; _anchors_self_test ) >/dev/null 2>&1
check "  and fails when links_of returns nothing"   "$?" "1"
( anchors_of() { :; }; _anchors_self_test ) >/dev/null 2>&1
check "  and fails when anchors_of returns nothing" "$?" "1"
SELFOUT=$( ( links_of() { :; }; _anchors_self_test ) 2>&1 || true )
check "  and names which half broke"        "$(grep -c 'links_of returned' <<<"$SELFOUT")" "1"

# The slug rule, against the one heading it was confirmed on.
check "slug: v0.1.0-rc6 heading"  "$(slug 'Known issue in v0.1.0-rc6')" "known-issue-in-v010-rc6"
check "slug: it is NOT the DOM form" \
      "$(slug 'Known issue in v0.1.0-rc6' | grep -c 'user-content')" "0"
check "slug: hyphens survive"     "$(slug 'Status & known limitations')" "status--known-limitations"

# A crafted tree must NOT be a repository: mode_in and md_files both answer
# differently inside one, and a copied .git would have them read the ORIGINAL
# index instead of the files just crafted. tar's --exclude matches differently
# across implementations, so the removal is explicit rather than trusted, and
# the assertion below turns a platform difference into a failing test instead of
# a control that quietly measures the wrong tree.
craft() {                                         # <name> -> a tree that is NOT a repository
    local d="$WORKDIR/$1"; rm -rf "$d"; mkdir -p "$d"
    tar -cf - --exclude .git -C "$ROOT" . 2>/dev/null | tar -xf - -C "$d"
    rm -rf "$d/.git"
    echo "$d"
}
# Takes the gate as its first argument. A control that names one gate and is
# reused for another measures the wrong subject — see CONTRIBUTING.
control() { local out rc; out=$("$1" "$3" 2>&1); rc=$?
    check "$2 -> refused"           "$rc" "1"
    check "  for the stated reason" "$(grep -c "$4" <<<"$out")" "1"; }

# THE scenario this was built for: the heading goes, the link stays. The heading
# to delete is DERIVED from the link, not named. The first version named the rc6
# section — and the very next commit removed it, which would have left this
# control crafting a tree identical to the real one and passing on nothing.
drop_heading_for() {                              # <file> <anchor>
    local f=$1 want=$2 line out=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^#{1,6}[[:space:]]+(.*)$ ]] && [[ "$(slug "${BASH_REMATCH[1]}")" == "$want" ]]
        then continue; fi
        out+="$line"$'\n'
    done < "$f"
    printf '%s' "$out" >"$f"
}
D=$(craft heading_removed)
check "a crafted tree is not a repository" \
      "$(git -C "$D" rev-parse --is-inside-work-tree 2>/dev/null || echo no)" "no"
printf '\nSee [the section](#a-target-heading).\n\n## A target heading\n' >>"$D/docs/OPERATING.md"
gate_anchors "$D" >/dev/null
check "fixture: the link resolves while its heading stands" "$?" "0"
ANC=$(links_of "$D/docs/OPERATING.md" | tail -1 | sed 's/.*\t//')
check "  and the anchor was derived from the link"          "$ANC" "a-target-heading"
drop_heading_for "$D/docs/OPERATING.md" "$ANC"
control gate_anchors "the heading is deleted and the link left behind" "$D" "anchor does not exist"

D=$(craft anchor_typo)
printf '\nSee [the thing](#no-such-heading-here).\n' >>"$D/docs/INSTALL.md"
control gate_anchors "a link to an anchor that never existed" "$D" "no-such-heading-here"

# A tree with no anchor links is not an error, and saying so is the whole point
# of the self-test. This used to refuse here.
D=$(craft no_links)
sed -i.bak 's/](#/](/g' "$D"/*.md "$D"/docs/*.md && rm -f "$D"/*.bak "$D"/docs/*.bak
NOL=$(gate_anchors "$D"); check "no in-page links anywhere -> still passes" "$?" "0"
check "  and says the derivation was verified" "$(grep -c 'derivation verified' <<<"$NOL")" "1"

# A heading-shaped line inside a code fence must not satisfy a link.
D=$(craft fenced_heading)
# shellcheck disable=SC2016  # the markdown fence is literal text, not substitution
printf '\nSee [it](#pretend-heading).\n\n```bash\n# pretend heading\n```\n' >>"$D/docs/OPERATING.md"
control gate_anchors "a fenced comment does not count as a heading" "$D" "pretend-heading"
# Control the other way: the SAME text as a real heading must resolve, so the red
# above came from the fence and not from the slug or the link syntax.
printf '\n## pretend heading\n' >>"$D/docs/OPERATING.md"
gate_anchors "$D" >/dev/null; check "  and as a real heading it resolves" "$?" "0"

# ---------------------------------------------------------------------------
# The README's test badge counts the suites that exist.
#
# It is a claim about this repository, and a hand-maintained number drifts the
# moment someone adds a file: it read 19 while tests/ held 20, which is what put
# a check on it in the first place.
#
# That check lived in .github/workflows/ci.yml and was wrong. It pulled every
# digit out of `tests-22%20suites` — and %20, the URL-encoded space, contains a
# 20 — so it compared a two-line string against one number and could never pass.
# It went red on its first run, at a badge value that was correct.
#
# It is here rather than in a workflow for the reason the tool gate is: a check
# with no controls is decoration, and controls only run where the suites run. The
# defect above survived because it was verified by retyping a simpler version of
# it in a shell, which is a model of the check rather than the check.
# ---------------------------------------------------------------------------
badge_count() {                                   # <root> -> the number on the badge
    sed -n 's/.*tests-\([0-9][0-9]*\)%20suites.*/\1/p' "$1/README.md"
}
suite_count() {                                   # <root> -> files in tests/
    find "$1/tests" -maxdepth 1 -name 'test_*.sh' -type f 2>/dev/null | wc -l | tr -d ' '
}
gate_badge() {                                    # <root> -> 0 + summary, or 1 + reason
    local root="$1" have want
    have=$(badge_count "$root"); want=$(suite_count "$root")
    [[ -n "$have" ]] || { echo "no test badge found in README.md"; return 1; }
    [[ "$have" =~ ^[0-9]+$ ]] || { echo "the badge did not yield one number: [${have//$'\n'/ }]"; return 1; }
    [[ "$want" =~ ^[1-9][0-9]*$ ]] || { echo "counted ${want} suites in tests/ — the count broke, not the badge"; return 1; }
    [[ "$have" == "$want" ]] || { echo "README badge says ${have} suites, tests/ holds ${want}"; return 1; }
    echo "badge and tests/ agree on ${want} suites"
    return 0
}

echo "== the README test badge counts the suites that exist =="
OUTB=$(gate_badge "$ROOT"); RCB=$?
check "badge matches the files on disk"     "$RCB" "0"
# The control that would have caught the %20 defect: the badge must yield exactly
# ONE number. Extracting every digit also finds the 20 inside the encoded space.
check "  and the badge yields ONE number"   "$(badge_count "$ROOT" | wc -l | tr -d ' ')" "1"
check "  and it is the suite count"         "$(badge_count "$ROOT")" "$(suite_count "$ROOT")"
check "  and the summary says so"           "$(grep -c 'badge and tests/ agree' <<<"$OUTB")" "1"

D=$(craft badge_drift)
sed -i.bak 's/tests-[0-9]*%20suites/tests-19%20suites/' "$D/README.md" && rm -f "$D"/*.bak
control gate_badge "the badge drifts from the file count" "$D" "README badge says 19"

D=$(craft badge_gone)
sed -i.bak 's/tests-[0-9]*%20suites/tests-suites/' "$D/README.md" && rm -f "$D"/*.bak
control gate_badge "the badge is unparseable" "$D" "no test badge found"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
