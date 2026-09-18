## Private build overlay (advanced)

The public build is **vanilla**. If a patch is present under `private/` (which is
git-ignored), the toolchain runs `git apply --check` against the checked-out tag
and applies it only if that is clean. A patch that is present but does **not**
apply is a hard stop: the build refuses rather than quietly producing a vanilla
binary you believe is patched. Either update the patch for the tag, or move it
out of the overlay directory to build vanilla on purpose. No overlay at all is
the normal public path and stays silent. Nothing about that overlay is in this
repo.

