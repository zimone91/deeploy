#!/usr/bin/env bash
# In-page links must point at headings that exist.
#
# The class has bitten this repository once already, in a different shape: six
# docs/ links in the README resolved in the working tree and were dead inside the
# release tarball, because git archive packs tracked files only. This is the same
# failure one level down — a link to an anchor on the same page, after the
# heading it names has been deleted.
#
# The specific reason it exists now: the next commit removes the "Known issue in
# v0.1.0-rc6" section, and README carries a link to its anchor near the top. The
# version gate cannot catch that — it matches v0.1.0-rc6 and the anchor spells it
# v010-rc6, with the dots gone. A gate written against one's own next commit is
# worth more than the one link it currently guards.
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

gate_anchors() {                                  # <root> -> 0 + summary, or 1 + reason
    local root="$1" f line t a target have n=0 dead=""
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

    (( n > 0 )) || { echo "derived no in-page links at all — the derivation broke, not the docs"; return 1; }
    [[ -z "$dead" ]] || { echo "links whose anchor does not exist:${dead}"; return 1; }
    echo "${n} in-repository anchor link(s) checked, all resolve"
    return 0
}

echo "== anchors: every in-page link points at a heading that exists =="
OUT=$(gate_anchors "$ROOT"); RC=$?
check "gate passes on this tree"            "$RC" "0"
check "  and it checked more than zero"     "$(grep -cE '^[1-9][0-9]* in-repository' <<<"$OUT")" "1"

# The slug rule, against the one heading it was confirmed on.
check "slug: v0.1.0-rc6 heading"  "$(slug 'Known issue in v0.1.0-rc6')" "known-issue-in-v010-rc6"
check "slug: it is NOT the DOM form" \
      "$(slug 'Known issue in v0.1.0-rc6' | grep -c 'user-content')" "0"
check "slug: hyphens survive"     "$(slug 'Status & known limitations')" "status--known-limitations"

craft() { local d="$WORKDIR/$1"; rm -rf "$d"; mkdir -p "$d"
    tar -cf - --exclude .git -C "$ROOT" . 2>/dev/null | tar -xf - -C "$d"; echo "$d"; }
control() { local out rc; out=$(gate_anchors "$2" 2>&1); rc=$?
    check "$1 -> refused"           "$rc" "1"
    check "  for the stated reason" "$(grep -c "$3" <<<"$out")" "1"; }

# THE scenario this was built for: the heading goes, the link stays.
D=$(craft heading_removed)
grep -v '^## Known issue in v0.1.0-rc6$' "$ROOT/README.md" >"$D/README.md"
control "the heading is deleted and the link left behind" "$D" "anchor does not exist"

D=$(craft anchor_typo)
printf '\nSee [the thing](#no-such-heading-here).\n' >>"$D/docs/INSTALL.md"
control "a link to an anchor that never existed" "$D" "no-such-heading-here"

D=$(craft no_links)
sed -i.bak 's/](#/](/g' "$D"/*.md "$D"/docs/*.md && rm -f "$D"/*.bak "$D"/docs/*.bak
control "no in-page links anywhere" "$D" "derived no in-page links"

# A heading-shaped line inside a code fence must not satisfy a link.
D=$(craft fenced_heading)
# shellcheck disable=SC2016  # the markdown fence is literal text, not substitution
printf '\nSee [it](#pretend-heading).\n\n```bash\n# pretend heading\n```\n' >>"$D/docs/OPERATING.md"
control "a fenced comment does not count as a heading" "$D" "pretend-heading"
# Control the other way: the SAME text as a real heading must resolve, so the red
# above came from the fence and not from the slug or the link syntax.
printf '\n## pretend heading\n' >>"$D/docs/OPERATING.md"
gate_anchors "$D" >/dev/null; check "  and as a real heading it resolves" "$?" "0"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
