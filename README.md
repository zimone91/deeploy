<h1 align="center">DeePloy</h1>

<p align="center">
  <em>Bare Ubuntu box → synced Solana mainnet-beta validator, in one interactive run.</em>
</p>

<p align="center">
  <a href="https://github.com/zimone91/deeploy/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/zimone91/deeploy/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="tests" src="https://img.shields.io/badge/tests-23%20suites-brightgreen">
  <img alt="shellcheck" src="https://img.shields.io/badge/shellcheck%200.11.0-clean-brightgreen">
  <img alt="status" src="https://img.shields.io/badge/status-release%20candidate-orange">
  <a href="https://github.com/zimone91/deeploy/releases"><img alt="release" src="https://img.shields.io/github/v/release/zimone91/deeploy?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

DeePloy takes a fresh Ubuntu 24.04 server to a synced Agave + Jito-BAM
mainnet-beta validator at `catchup 0`. It builds the client from source, tunes
the box for it, and leaves the staked-key swap to you.

### What you need

```
Ubuntu 24.04 x86-64 · root · proven on 377 GiB RAM, 2× 1.92 TB data NVMe + a system disk
one reboot · a disk wipe you confirm by typing yes · 30-90 min build
```

## ⚠️ Your staked key

DeePloy never generates, copies, moves, or transmits your staked key, and it
won't put the key on the box for you. The node syncs on a throwaway identity;
you swap the real key in yourself at the end.

It does read the keypair file, from three commands. `install` and `upgrade`
derive its public key to check it against the running identity. `dz-connect`
derives it twice more and signs one DoubleZero passport message with it. Those
five reads are local and read-only.

`dz-connect` then passes the keypair path to `doublezero-solana`, which DeePloy
does not control. That handoff, and the reasoning behind each read, are in
[docs/KEY-MODEL.md](docs/KEY-MODEL.md). Skip DoubleZero and it never happens.

## Install (one command)

    sh -c "$(curl -sSfL https://zim.one/deeploy/v0.1.0-rc7)"

That downloads the pinned release and its `SHA256SUMS`, checks the tarball
against the manifest, and unpacks it into `./deeploy-v0.1.0-rc7`. It refuses to
start if that directory already exists. With `sudo` available it hands the
checkout to root; without it, it prints the two commands for you to run.

Then it stops. DeePloy wipes disks, rewrites GRUB and reboots the box, so you
read the checkout and start the install yourself:

```bash
cd deeploy-v0.1.0-rc7
sudo ./deeploy.sh install --dry-run   # prints the whole plan, changes nothing
sudo ./deeploy.sh install
```

The paranoid path, which is the one to take for a tool that runs as root:

    curl -fsSLO https://raw.githubusercontent.com/zimone91/deeploy/v0.1.0-rc7/get-deeploy.sh

Read it, then run `sh get-deeploy.sh`. Or from source:

    git clone --branch v0.1.0-rc7 https://github.com/zimone91/deeploy
    cd deeploy
    sudo chown -R root:root . && sudo chmod -R go-w .
    sudo ./deeploy.sh install --dry-run

The `chown` there is not tidiness. The post-reboot resume service runs this
checkout as root at boot, so phase 0 refuses to install it out of a directory
another local user could write to.

The `chmod` is not tidiness either. Under some umasks — `002` is the common one
— a fresh clone or an unpacked tarball comes out group-writable, and the same
two commands above remove it.

## Verify what you downloaded

Release tarballs ship a `SHA256SUMS` next to them, produced by the tagged
release workflow from `git archive` of that exact tag:

```bash
sha256sum -c SHA256SUMS        # must print: OK
tar tzf deeploy-vX.Y.Z.tar.gz | grep -vc '/$'   # how many files, directories aside
tar tzf deeploy-vX.Y.Z.tar.gz                   # then read the list itself
```

That list should hold no submodules, no binaries, no build output, and nothing
whose name you cannot place.

Tarball and manifest travel the same channel, so that pair catches a damaged or
altered download rather than a compromised repository. `get-deeploy.sh` travels
a different one, served from zim.one, and its digest is published in the release
notes. Comparing those two is the check that says something about origin:

```bash
curl -sSfL https://zim.one/deeploy/v0.1.0-rc7 | tail -n +2 | sha256sum
```

`tail -n +2` drops the one line the endpoint adds to pin the version. Tags are
annotated but not signed, so a checksum proves integrity, not authorship.

## What it leaves on the box

DeePloy is not a daemon and does not supervise the validator. `solana.service`
runs the node. The rest of what it installs is DeePloy's own and keeps running
without it: `performance-tweaks.service` and `solana-sysctl.service` reapply
host tuning at every boot, `solana-poh-pin` re-pins the PoH thread, and an mlx5
or bnxt_en NIC adds a tuning unit.

One unit runs DeePloy itself. `deeploy-resume.service` carries the install
across its single reboot. The automatic resume disables it; a manual
`install --resume` does not, so after one of those run
`systemctl disable deeploy-resume.service`. Neither path deletes the unit file.

## Documentation

- [docs/INSTALL.md](docs/INSTALL.md) — hardware, the disk trade-off, phases 0-8, MEV
- [docs/OPERATING.md](docs/OPERATING.md) — commands and `deeploy.conf`
- [docs/UPGRADE.md](docs/UPGRADE.md) — upgrades on a staked box
- [docs/KEY-MODEL.md](docs/KEY-MODEL.md) — the staked key in full
- [docs/OVERLAY.md](docs/OVERLAY.md) — private build overlay
- [docs/FAILOVER.md](docs/FAILOVER.md) — the separate failover tool

Running the tests and the gate: [CONTRIBUTING.md](CONTRIBUTING.md).

## Status & known limitations

DeePloy is a release candidate. The full cycle, from install through
`catchup 0` to the key swap, was proven on two production boxes in June 2026.
Nothing since that run has been executed on hardware, the revision you are
reading included.

- Agave 4.2 inverted the AF_XDP default, so the generated `validator.sh` had to
  change on a path that was hardware-proven. Tests cover the new form. Metal
  has not seen it.
- `upgrade` is beta. Tests exercise it; a real client upgrade on a staked box
  has not.
- `upgrade --rollback` does not go through the staked-identity check.
- `dz-connect` hands your keypair path to `doublezero-solana`, which comes from
  an apt repository and is not pinned here.
- The build downloads rustup-init, the anza installer, jito-solana at a mutable
  tag and a clone of the XDP helper, and runs all of it as root without checking
  a checksum or a signature.
- Disk eligibility is checked against the layouts this has run on. Read the
  table it prints before you type `yes`.
- The `mlx5` IRQ map is static, not computed from the running topology.
- You are responsible for your keys, your stake, and your slots. No warranty.

Vulnerabilities go through the private advisory link in
[SECURITY.md](SECURITY.md), not a public issue.

## License

MIT — see [LICENSE](LICENSE).

---

Created and maintained by [zimone91](https://github.com/zimone91).
