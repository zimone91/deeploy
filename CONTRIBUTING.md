# Contributing to DeePloy

DeePloy is written to be **read before it is run as root** on a box that holds
real stake. Contributions are held to the same bar: small, auditable, tested.

## The gate (run before every PR)

```bash
for f in deeploy.sh run_tests.sh lib/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x deeploy.sh run_tests.sh lib/*.sh tests/*.sh     # shellcheck 0.11.0 — see below
./run_tests.sh                                   # exits non-zero if anything failed
```

- **Use `run_tests.sh`, not a `for` loop.** The loop that printed `FAILED: $t`
  still exited 0, so it was green to any CI or pre-commit hook wrapping it. The
  runner fails a suite that exits non-zero, reports failures, *or* never prints
  its `RESULT` line (a suite that dies mid-run is silence, not success).

- **The test-count badge in the README is maintained by hand.** It reads
  `1117 across 17 suites`. If you add or remove a suite or change the assertion
  count, update the badge in the same commit — nothing checks it, so it will
  drift silently otherwise.

- **shellcheck is pinned to 0.11.0** (what CI installs). Older versions (e.g.
  Ubuntu 24.04's apt 0.9.0) emit false positives this repo does not carry
  exceptions for.
- Tests are self-contained: no root, no network, no live node. Every external
  command a module touches is mockable by shadowing it with a shell function.

## Conventions

- **Per-finding commits**, subject format `area: description (IDs)` — one
  logical fix per commit, with its tests in the same commit.
- **Fixes come with tests.** A behavior fix without a regression test that
  fails on the old code is not done.
- Everything is bash + `set -Eeuo pipefail` at the entrypoint: mind the errexit
  gotchas (`var=$(pipeline)` on commands that legitimately return non-zero,
  functions ending in `while read` loops).
- All mutations go through `run()` / `write_file` / `ensure_*` so `--dry-run`
  stays truthful and every touched system file is backed up first.
- Never commit secrets, real pubkeys/IPs/hostnames, or key material — test
  fixtures use synthetic identifiers (RFC 5737 IPs, throwaway base58).

## Releases

Tags are annotated and must match `DEEPLOY_VERSION` in `lib/common.sh` (CI
enforces this). They are **not GPG-signed** during the release-candidate
series: the published `SHA256SUMS` proves integrity, not provenance — see
"Verify what you downloaded" in the README. Signing (`git tag -s vX.Y.Z`) is a
separate, later step; do not document it as done until it is.

The release workflow builds the tarball + `SHA256SUMS` as a draft release for
the maintainer to verify and publish.

## Sign-off

No DCO/sign-off required. By submitting a PR you license your contribution
under the repository's MIT license.
