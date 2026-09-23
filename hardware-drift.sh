#!/usr/bin/env bash
# How far the deployment path has drifted from the last tree that ran on metal.
#
# Prints one line, computed. It exists because a release page that says what
# changed is written by a person and a person can be wrong about it: the rc7
# notes ended "Deployment logic, the gates around destructive steps and the key
# model are unchanged" one paragraph after listing three new gates, two of them
# around the disk wipe. A number derived from the history cannot make that
# mistake, whatever the prose above it says.
#
# Usage: hardware-drift.sh [<ref>]     (default HEAD)
# Exit:  0 = measured   1 = the anchor is not in this history   2 = cannot measure
set -uo pipefail

# ---------------------------------------------------------------------------
# THE ANCHOR. One place, one line of provenance, and it is not a guess.
#
# 676be33 — "validatorcfg: close the unattended MEV crash trap (R3, R4)",
# 2026-06-15, the last commit before the F series.
#
# The June checkpoints record the hardware round (the F series) as closed at a
# HEAD this repository no longer carries: the public history was rewritten, so
# those SHAs do not resolve here and the anchor is mapped by commit subject
# instead. The F series was written FROM that round rather than run during it,
# but the findings tracker records F1/R16 as confirmed on the box — so part of
# it did run, and the truth lies somewhere between this commit and the end of
# the series. This is the earlier of the two. It can only overstate the drift,
# never hide it, and the 60 lines between them do not change what the line says.
#
# If a checkout is ever measured on the mlx5 box, this is the one line to edit.
# ---------------------------------------------------------------------------
HW_ANCHOR="${HW_ANCHOR:-676be33}"

die() { printf 'hardware-drift: %s\n' "$*" >&2; exit "${2:-1}"; }

command -v git >/dev/null 2>&1 || die "git is not installed — cannot measure" 2
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — cannot measure" 2

# A shallow clone is the answer that looks like the other one: the anchor is not
# reachable, and asking whether it EXISTS returns the same no as a history that
# really lost it. CI checks out with depth 1 by default, so this is the ordinary
# case on a runner, and it must not be reported as a rewritten history.
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    die "shallow clone — the anchor cannot be reached from a depth-limited checkout. Use fetch-depth: 0. NOT MEASURED, and not a claim that the anchor is gone" 2
fi

git cat-file -e "${HW_ANCHOR}^{commit}" 2>/dev/null \
    || die "anchor ${HW_ANCHOR} is not in this history — it was rewritten, or the anchor is wrong. The history is complete here, so this is a real failure" 1

ref="${1:-HEAD}"
git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || die "cannot resolve ref '${ref}'" 2

subject=$(git log -1 --format=%s "$HW_ANCHOR")
date=$(git log -1 --format=%ad --date=short "$HW_ANCHOR")
short=$(git rev-parse --short "$HW_ANCHOR")
stat=$(git diff --shortstat "$HW_ANCHOR" "$ref" -- deeploy.sh lib/)
[[ -n "$stat" ]] || stat="no changes"

# The anchor is a LOWER BOUND, not the last tree that ran on metal: part of the F
# series was confirmed on the box and part was written afterwards. Saying "since
# the last hardware run" would assert the bound is the thing it bounds, and that
# wording would have gone into every future release.
printf 'Changes in the deployment path since %s ("%s", %s): %s. The last commit run on hardware is no earlier than %s, so these figures can only overstate what has not run on hardware.\n' \
    "$short" "$subject" "$date" "$(printf '%s' "$stat" | sed 's/^ *//')" "$short"
