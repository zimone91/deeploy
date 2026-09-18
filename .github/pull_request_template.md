## What this changes, and why

<!-- The diff already says what. Why is the part that cannot be reconstructed
later, and it is what the commit message will be read for in a year. -->

## Checklist

- [ ] **Tests added, and they fail on the old code.** A behaviour fix whose test
      passes before the fix is not a regression test.
- [ ] **`--dry-run` checked** on every path this touches, and it still prints
      what actually happens.
- [ ] **No secrets, real pubkeys, IPs or hostnames.** Fixtures use synthetic
      identifiers — RFC 5737 addresses, throwaway base58.
- [ ] **Destructive behaviour unchanged**, or changed and said so here in words.
      Disk wipes, GRUB/fstab/sshd rewrites and validator restarts require the
      confirmation the code promises; nothing weakens one quietly.
- [ ] **The claim being corrected was grepped across the whole tree**, not only
      the file it was noticed in — see "When you correct a claim" in
      CONTRIBUTING. Statements in this repo live in several places at once, and
      fixing the copy you noticed leaves the strongest one standing.
- [ ] **No `Co-Authored-By` trailers.**
- [ ] The gate passes: `bash -n`, `shellcheck -x` 0.11.0, `./run_tests.sh`.
      Say which platform you ran it on. CI is ubuntu-24.04, and green on macOS
      has already meant red there — `tar -xzf` forks gzip under GNU tar and does
      not under BSD tar.
