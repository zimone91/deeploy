# Security Policy

DeePloy runs **as root** on machines that hold **real mainnet stake**. Treat
every finding accordingly.

## Reporting a vulnerability

Please report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/zimone91/deeploy/security/advisories/new)
("Report a vulnerability"). Do **not** open a public issue for anything
exploitable.

You should get an acknowledgment within a few days. Please include enough
detail to reproduce (the affected file/function, a minimal scenario, and what
an attacker gains).

## Scope — what counts as a vulnerability here

- Anything enabling **key exfiltration** (the staked validator keypair, the
  DoubleZero ID, or any keypair DeePloy touches — including via logs, backups,
  or exported configs).
- **Unauthorized destructive operations** — any path that can wipe a disk,
  rewrite GRUB/fstab/sshd, or restart a staked validator without the explicit
  confirmation the code promises (e.g. a `require_yes` bypass).
- **Privilege escalation** enabled by DeePloy's artifacts (generated units,
  scripts, file permissions).
- **Supply-chain weaknesses in the fetch paths** (rustup, the anza installer,
  the jito-solana clone, the DoubleZero repo setup, CI tooling downloads).

Hardware-tuning trade-offs, style issues, and feature requests are ordinary
issues, not security reports.

## Supported versions

Only the **latest tagged release** receives security fixes. There is no
backporting.

## No bounty

This is an unfunded open-source operator tool. There is no bug bounty — just
credit in the changelog (if you want it) and sincere thanks.
