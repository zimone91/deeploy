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
# 1729f1e — "version: 0.1.0-rc9", 2026-10-05, the commit tagged v0.1.0-rc9.
#
# Its release tarball, fetched and checked by get-deeploy.sh, ran on one
# mainnet box with an mlx5 NIC on 2026-10-05: install --dry-run; install,
# phases 0-8 with the reboot between 7 and 8, to catchup 0 on the throwaway
# identity, with XDP retransmit on two cores in zero-copy mode; verify;
# upgrade --dry-run; upgrade with a private overlay, which rebuilt and
# restarted solana; verify again. The node ran on into 2026-10-06.
#
# Those runs did not include dz-connect, export, import, upgrade --rollback,
# or anything that reads the staked key: it was not on the box then. The swap
# was rehearsed with decoy keys only.
#
# The anchor before it, 676be33 (2026-06-15, the last commit before the F
# series), was a lower bound: the June hardware round closed at a HEAD the
# rewritten public history no longer carries.
#
# When a later tree runs on the box, this is the one line to edit.
# ---------------------------------------------------------------------------
HW_ANCHOR="${HW_ANCHOR:-1729f1e}"

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

# The line says "no earlier than", not "the last commit run on hardware": a
# later tree can run on the box before anyone edits the anchor, and this line
# goes onto every release page. Worded so, it stays true, and the figure can
# only overstate. It counts changes since the anchor; what did not run on
# metal even at the anchor is listed above, not counted here.
printf 'Changes in the deployment path since %s ("%s", %s): %s. The last commit run on hardware is no earlier than %s, so these figures can only overstate what has not run on hardware.\n' \
    "$short" "$subject" "$date" "$(printf '%s' "$stat" | sed 's/^ *//')" "$short"
