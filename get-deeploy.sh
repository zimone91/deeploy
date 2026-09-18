#!/bin/sh
# DeePloy — bootstrap. Fetches a pinned release, verifies it against its
# SHA256SUMS, hands the checkout to root, and stops.
#
#   sh -c "$(curl -sSfL https://zim.one/deeploy/v0.1.0-rc6)"   # pinned
#   sh -c "$(curl -sSfL https://zim.one/deeploy)"              # default version
#
# IT DOES NOT DEPLOY. DeePloy wipes disks, rewrites GRUB and reboots the box.
# This script brings you the code and the proof it arrived intact; you start
# the deployment yourself, with the command printed at the end, after reading
# what you are about to run as root.
#
# WHAT THE CHECKSUM BUYS YOU, HONESTLY: the tarball and its SHA256SUMS travel
# the same channel, so they catch a corrupted or tampered download — not a
# compromise of the repository itself. This bootstrap travels a different one:
# it is served from zim.one, and its own SHA256 is published in the GitHub
# release notes, so that one you can cross-check against a second source:
#
#   curl -sSfL https://zim.one/deeploy/v0.1.0-rc6 | tail -n +2 | sha256sum
#
# tail -n +2 drops the one line the endpoint prepends to pin the version;
# without it the digest will not match, and the mismatch would mean nothing.
# Verification failure aborts; there is no continue-without-verifying path.
#
# https://github.com/zimone91/deeploy
set -eu

# Bracket ranges like [0-9A-Za-z] are resolved by COLLATION, not by code point.
# Under bash (which is /bin/sh on macOS) in a UTF-8 locale, 'e' with an acute
# accent sorts inside a-z and slips through the tag check below; under LC_ALL=C
# it does not. The one place in this script that guards a string destined for a
# URL must not depend on the user's locale, so pin it for the whole run — which
# also makes the awk parse of SHA256SUMS deterministic.
export LC_ALL=C

REPO="zimone91/deeploy"
TAG="${DEEPLOY_INSTALL_TAG:-v0.1.0-rc6}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# The tag reaches an URL that this script builds, so it is validated HERE and
# not only in the Cloudflare route: the route never sees
# `DEEPLOY_INSTALL_TAG=... sh get-deeploy.sh`. Same rule as JITO_TAG — the
# consumer checks its own input. Pure shell on purpose: a validator that needs
# grep would be skipped on a box without it.
case "$TAG" in
    v*) ;;
    *) die "DEEPLOY_INSTALL_TAG '${TAG}' must start with 'v' (e.g. v0.1.0-rc6)" ;;
esac
case "$TAG" in
    *[!0-9A-Za-z._-]*) die "DEEPLOY_INSTALL_TAG '${TAG}' contains characters that are not allowed in a tag" ;;
esac
if [ "${#TAG}" -lt 2 ] || [ "${#TAG}" -gt 41 ]; then
    die "DEEPLOY_INSTALL_TAG '${TAG}' is not a plausible tag (2-41 characters)"
fi

TARBALL="deeploy-${TAG}.tar.gz"
DEST="deeploy-${TAG}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

command -v curl >/dev/null 2>&1 || die "curl is required to download the release"
command -v tar  >/dev/null 2>&1 || die "tar is required to unpack the release"

# No hash tool means no verification, and no verification means no install.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "neither sha256sum nor shasum is available — refusing to install without verifying the download"
    fi
}

[ -e "$DEST" ] && die "${DEST} already exists here — move or remove it first; this script will not overwrite it"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

say ""
say "  DeePloy  ·  ${TAG}  ·  bootstrap"
say ""
say "  fetching ${TARBALL}"
curl -sSfL -o "$TMP/$TARBALL" "${BASE}/${TARBALL}" || die "could not download ${BASE}/${TARBALL}"
say "  fetching SHA256SUMS"
curl -sSfL -o "$TMP/SHA256SUMS" "${BASE}/SHA256SUMS" || die "could not download ${BASE}/SHA256SUMS"

want="$(awk -v f="$TARBALL" '{ name = $2; sub(/^\*/, "", name); if (name == f) print $1 }' "$TMP/SHA256SUMS")"
[ -n "$want" ] || die "SHA256SUMS has no entry for ${TARBALL} — refusing to install"
got="$(sha256_of "$TMP/$TARBALL")"

if [ "$want" != "$got" ]; then
    die "checksum mismatch for ${TARBALL}
  expected ${want}
  actual   ${got}
nothing was unpacked."
fi
say "  checksum ok  ${got}"

# Verified before anything lands on disk, so a mismatch leaves no directory to
# clean up rather than leaving one and hoping the cleanup runs.
# --no-same-owner: under root, GNU tar would otherwise restore uid/gid from the
# archive. Ours come from `git archive`, which writes 0/0, so this changes
# nothing for our own releases — it just removes the case where a tarball gets
# to choose who owns the files it unpacks.
tar --no-same-owner -xzf "$TMP/$TARBALL" || die "could not unpack ${TARBALL}"
[ -d "$DEST" ] || die "${TARBALL} did not contain ${DEST}/"
say "  unpacked to ./${DEST}"

# Phase 0 refuses to install the boot-time resume service from a checkout that
# is not root-owned, because that service runs the checkout as root. Handing
# ownership over now is what makes the next command work.
owned=0
if [ "$(id -u)" = "0" ]; then
    chown -R root:root "$DEST" && chmod -R go-w "$DEST" && owned=1
elif command -v sudo >/dev/null 2>&1; then
    sudo chown -R root:root "$DEST" && sudo chmod -R go-w "$DEST" && owned=1
fi

say ""
if [ "$owned" = "1" ]; then
    say "  owner    root:root, group and world write removed"
else
    say "  NOT yet root-owned — no sudo here. Run these two first:"
    say "      sudo chown -R root:root ${DEST}"
    say "      sudo chmod -R go-w ${DEST}"
fi

# Everything above fetched and checked. Nothing above deployed anything, and
# this script never runs deeploy.sh: the destructive part starts when you type
# the next line, not when you ran this one.
say ""
say "  Nothing has been deployed. Read the source, then start it yourself:"
say ""
say "      cd ${DEST}"
say "      sudo ./deeploy.sh install --dry-run   # prints the whole plan, changes nothing"
say "      sudo ./deeploy.sh install"
say ""
