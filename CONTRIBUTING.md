# Contributing to DeePloy

DeePloy is written to be **read before it is run as root** on a box that holds
real stake. Contributions are held to the same bar: small, auditable, tested.

## The gate (run before every PR)

```bash
for f in deeploy.sh get-deeploy.sh run_tests.sh lib/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x deeploy.sh get-deeploy.sh run_tests.sh lib/*.sh tests/*.sh   # shellcheck 0.11.0 — see below
./run_tests.sh                                   # exits non-zero if anything failed
```

- **Use `run_tests.sh`, not a `for` loop.** The loop that printed `FAILED: $t`
  still exited 0, so it was green to any CI or pre-commit hook wrapping it. The
  runner fails a suite that exits non-zero, reports failures, *or* never prints
  its `RESULT` line (a suite that dies mid-run is silence, not success).

- **The test badge in the README is maintained by hand**, and now carries the
  number of suites and nothing else. It used to carry the assertion count too,
  which changed in nearly every commit and was therefore wrong more often than
  right; the suite count moves a few times a year. Adding or removing a suite
  means updating the badge in the same commit — nothing checks it. The habit
  worth keeping from this: a number written in prose is a claim, and a claim
  nothing verifies drifts until someone trusts it.

- **shellcheck is pinned to 0.11.0** (what CI installs). Older versions (e.g.
  Ubuntu 24.04's apt 0.9.0) emit false positives this repo does not carry
  exceptions for.
- Tests are self-contained: no root, no network, no live validator. Most
  modules are sourced into the suite's own shell, so an external command is
  mocked by shadowing it with a shell function. Two suites cannot work that
  way and say so in their headers: `test_bootstrap.sh` runs `get-deeploy.sh`
  as a separate `/bin/sh` process, where a function does not cross the process
  boundary, so it mocks with executable stubs on a restricted PATH; and:

- **`test_worker.sh` requires node**, because the worker is JavaScript and
  there is no way to exercise it from sh. This is not an optional extra: the
  release gate already imports `worker/index.mjs` to read the tag it serves,
  so a box that cannot run node cannot verify a release either. Without node
  the suite fails with that message — it does not report a skip. A check that
  cannot determine the answer does not get to report success.

## Conventions

- **Per-finding commits**, subject format `area: description (IDs)` — one
  logical fix per commit, with its tests in the same commit.
- **No `Co-Authored-By` trailers.** Commits in this repository carry one author.
- **No first person plural, anywhere a reader can reach it.** This repository
  has one author, so "we" is not a matter of voice; it is inaccurate. It applies
  to the README, `docs/`, `SECURITY.md`, release notes and the template in
  `release.yml` that generates them, the issue and PR templates, `CODEOWNERS`,
  and code comments — everything in a public repository can be read, and the
  number of authors does not change with the file extension. Name what acts, or
  address the reader: "the release workflow builds", not "we build"; "something
  you take on trust", not "something we assert". CHANGELOG is exempt for the
  same reason it is exempt from the grep rule below: its entries record what was
  written at the time. The two quoted counter-examples above are this bullet
  showing what it forbids; a grep for the rule will find them and they are not
  violations.
- **A tag's message is the release lede.** The release workflow reads the
  annotated tag through the API and puts its message at the top of the release
  notes, because GitHub shows a tag body nowhere on the release page. Write it
  for someone who has just landed there and has not read anything else: what
  this version is, and what is still not proven. A lightweight tag, or a message
  under 40 characters, fails the release rather than publishing a page with no
  lede.
- **When you correct a claim, grep the whole tree for it, not just the file you
  noticed it in.** Statements here are repeated across the README, CONTRIBUTING,
  module headers and the strings the tool prints; fixing one copy and leaving
  another is the most common defect this repo has had, and it always leaves the
  strongest version of the claim standing.
  **CHANGELOG is where that grep stops.** Its entries record what was true at a
  point in time; they are not claims about what is true now. Correcting a stale
  statement and rewriting history are different acts, and this rule licenses
  only the first — a changelog edited to agree with the present is a changelog
  that can no longer be used to find out when something changed.
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
the maintainer to verify and publish. It also takes a manual
`workflow_dispatch` with an existing tag, so a draft can be rebuilt without
moving a tag; it refuses to touch the assets of a release that is already
published, because a rebuild is not guaranteed to be byte-identical (a
different runner image or git version changes the gzip stream), so the checksum
could change under anyone who already recorded it.

## Sign-off

No DCO/sign-off required. By submitting a PR you license your contribution
under the repository's MIT license.
