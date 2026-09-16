<h1 align="center">DeePloy</h1>

<p align="center">
  <em>Bare Ubuntu box → synced Solana mainnet-beta validator, in one interactive run.</em>
</p>

<p align="center">
  <a href="https://github.com/zimone91/deeploy/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/zimone91/deeploy/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="tests" src="https://img.shields.io/badge/tests-1117%20across%2017%20suites-brightgreen">
  <img alt="shellcheck" src="https://img.shields.io/badge/shellcheck%200.11.0-clean-brightgreen">
  <img alt="status" src="https://img.shields.io/badge/status-release%20candidate-orange">
  <a href="https://github.com/zimone91/deeploy/releases"><img alt="release" src="https://img.shields.io/github/v/release/zimone91/deeploy?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

DeePloy takes a fresh Ubuntu 24.04 server to a synced **Agave + Jito-BAM**
mainnet-beta validator at `catchup 0`, built from source and tuned for it —
then hands you the manual staked-key swap. Plain `bash`, no daemons, no magic.

It is written to be **read before it is run as root on a box that will hold real
money**: modular, every system file backed up before it's touched, and a
`--dry-run` that prints the whole plan and changes nothing.

### What it does

- **Phases 0–8, idempotent and resumable** — one `install`, a single GRUB-gated
  reboot, and an unattended resume that finishes the job.
- **Never generates, copies, moves, or transmits your staked key.** The node
  syncs on a throwaway identity and you swap the real key in yourself. DeePloy
  does read the keypair file — locally, read-only, in exactly two places: to
  derive its public key, and to sign one DoubleZero passport message. See the
  section below — this is the core design.
- **Builds the client from source** at a pinned tag (`v4.2.1-jito`), with a
  minimum-supported floor so an incompatible client is refused *before* the
  30–90 minute build, not after.
- **Tunes the box for a validator:** CPU isolation via GRUB, PoH core pinning,
  IRQ affinity, XFS data disks, NIC tuning (`bnxt_en` / `mlx5_core`), and an
  explicit AF_XDP retransmit decision — never an implicit one.
- **Fails closed.** Destructive steps require a typed `yes`; `--yes` never
  auto-wipes. Preflight refuses an unsafe checkout in the first seconds.
- **Optional DoubleZero** (GRE/BGP tunnels, passport, multicast shred).
- **Lifecycle commands:** `verify`, `upgrade`, `export`, `import`, `dz-connect`.
- **1117 assertions across 17 suites**, `shellcheck` clean, gated in CI on every
  push — including a secret scan over the full history.

---

## ⚠️ Read this first — the staked-key model

DeePloy never **generates, copies, moves, or transmits** your real staked
validator key, and never places it on the box for you. The node syncs on a
throwaway identity and you swap the staked key in manually (step 2). The tool
does **read** the keypair file in two narrow, local, read-only ways — to derive
its **public** key (the identity≠vote check and the upgrade staked-restart guard)
and to produce a single DoubleZero passport signature during `dz-connect` — but
the private key is never written, copied, or sent off the box. Understand the
flow before you run it; this is what separates "fine on testnet" from "I know
what I'm doing on mainnet":

1. DeePloy brings the node up on a **throwaway "fake" identity** and lets it sync.
2. The **real staked key is moved in manually by you**, at the end, with the
   printed `set-identity` commands. DeePloy will not generate, copy, move, or
   transmit it (it reads the file only to derive the public key, and in
   `dz-connect` to sign one passport message).
3. The **tower is *not* transferred.** A fresh node started on an identity with no
   local tower **rebuilds its vote floor from the cluster** — the safe path for a
   first bring-up. (Moving a tower is only for a live-to-live failover swap, which
   is a *separate* tool, out of scope here.)
4. The node uses `--private-rpc` bound to `127.0.0.1`; RPC is never exposed.

If you don't want a node to come up and start voting on a fresh identity, **do not
run the final start phase on a key that is already staked elsewhere.**

There is **no warranty.** You are responsible for your keys, your stake, and your
slots. Read the source.

---

## Hardware & the disk trade-off

Target: a fresh Ubuntu 24.04 x86-64 box (built and proven on AMD EPYC,
377 GiB RAM, 2× ~1.92 TB data NVMe + a separate system disk).

**Client:** DeePloy pins `JITO_TAG="v4.2.1-jito"` and supports **v4.2.0-jito or
newer**. Older clients are refused before the build: the generated `validator.sh`
passes `--no-xdp` and `--poh-pinned-cpu-core`, neither of which exists before
4.2.0, so an older binary would build for 30-90 minutes and then refuse to start.

- **Ideal:** **two separate data NVMe** — `accounts` and `ledger` on *different*
  physical disks. This keeps snapshot packaging and accountsdb writes from
  competing for the same spindle/queue. DeePloy formats them XFS and mounts
  `/mnt/accounts` + `/mnt/ledger` (snapshots ride with the ledger disk).
- **Single disk or RAID:** works, but is **suboptimal** — accounts and ledger
  share one volume. DeePloy will deploy this layout and print a clear warning
  recommending separate NVMe. You are not blocked, but you should understand the
  I/O contention you're accepting.

The disk phase **detects** your disks, shows a table, proposes a mapping, and
**requires you to type `yes`** before wiping anything. `--yes`/`--post-reboot`
never auto-wipe.

---

## Get it

DeePloy is meant to be **read before it is run as root** — there is no `curl | sh`
one-liner by design. It wipes disks, rewrites GRUB, reboots the box, and runs as
root on a machine that will hold real stake; inspect it first.

```bash
# 1) Get the source — clone, or download a tagged release tarball
git clone https://github.com/zimone91/deeploy.git
cd deeploy

# 2) (release tarballs) verify the checksum before you trust it
#    sha256sum -c SHA256SUMS

# 3) READ it (this is the point of not having a curl|sh one-liner)
less deeploy.sh lib/*.sh

# 4) Hand it to root. The post-reboot resume service runs THIS checkout as root
#    at boot, so a user-writable path would let any local user swap the script
#    between install and the reboot. DeePloy refuses to install that service
#    from an unsafe checkout — preflight says so in the first seconds.
sudo chown -R root:root . && sudo chmod -R go-w .

# 5) Dry-run it (prints the whole plan, changes nothing), then run it for real
sudo ./deeploy.sh install --dry-run
sudo ./deeploy.sh install
```

> After step 4 the checkout belongs to root, so later updates need `sudo git pull`.

---

## Verify what you downloaded

Release tarballs ship a `SHA256SUMS` next to them, produced by the tagged
release workflow from `git archive` of that exact tag:

```bash
sha256sum -c SHA256SUMS        # must print: OK
tar tzf deeploy-vX.Y.Z.tar.gz  # 44 files, no submodules, no binaries
```

The supply chain is pinned on purpose: GitHub Actions are pinned by commit SHA
(not by tag), `shellcheck` is pinned to 0.11.0 and its download is
SHA256-verified before it runs, and a secret scan runs over the **entire** git
history on every push.

**Tags are annotated but not yet GPG-signed** during the release-candidate
series. Until they are, a checksum proves integrity, not provenance — clone over
HTTPS/SSH from this repository rather than trusting a mirror.

---

## Quickstart

```bash
sudo ./deeploy.sh install            # phased, interactive, resumable
sudo ./deeploy.sh install --dry-run  # print the full plan, change nothing
```

The install runs phases 0–7 interactively, then (if CPU isolation changed the
kernel cmdline) **reboots once** and **auto-resumes** to finish phase 8 — it
verifies the isolation actually applied before starting the validator, then waits
for `catchup 0` and prints the manual staked-key swap instructions.

## Phases

| # | Phase | What it does |
|---|---|---|
| 0 | Preflight | root/OS/CPU/RAM/disk/NIC audit, mainnet genesis guard, closest-region scoring |
| 1 | Base | packages, SSH-port change (verify-or-rollback), core ufw |
| 2 | Tuning | **dynamic CPU isolation → GRUB**, performance-tweaks, sysctl, NOFILE → reboot gate |
| 3 | Disk | detect → confirm → blkdiscard + mkfs.xfs + mount + fstab + symlink |
| 4 | Toolchain | rustup, anza CLI, build jito-solana @ tag (LTO, `target-cpu=native`), setcap |
| 5 | Keys | generate the unstaked sync identity; print where the real key goes |
| 6 | Validator config | generate `validator.sh`, `solana.service`, logrotate, PoH-pin, NIC setup |
| 7 | DoubleZero | (optional, prompted) PREPARE only: packages, env→mainnet-beta, ufw (GRE, BGP, 44880) + old-server-disconnect reminder + pointer — ID-migration, passport, and connect are the separate post-swap `dz-connect` step |
| 8 | Start | free-disk precheck → start → `catchup 0` → pin PoH → verify → summary |

## Commands

```
deeploy.sh install        # the phased deploy (resumable, --dry-run-able)
deeploy.sh upgrade        # rebuild to a new tag; keeps the previous for rollback
deeploy.sh upgrade --rollback   # flip active_release back to the previous release
deeploy.sh verify         # run the post-install verification block on demand
deeploy.sh export         # write deeploy.conf (paths/pubkeys/settings only)
deeploy.sh import         # load deeploy.conf into state (import --rescore re-pings region)
deeploy.sh dz-connect     # DoubleZero connect: passport + ibrl + multicast (run AFTER the manual staked-key swap)
```

Flags: `--dry-run`, `--resume`, `--only <phase>`, `--force`, `--yes`,
`--config <path>`, `--rescore`, `--rollback`.

## Config (`deeploy.conf`)

A single bash-env file (see [`deeploy.conf.example`](deeploy.conf.example)) holding
**paths, pubkeys, and settings only — never key material**, `chmod 600`.
`deeploy export` writes it; `deeploy import` validates it (and **refuses any file
that contains embedded key material**) before loading it. This is the
"reproduce an identical box without re-typing" path — and what a DoubleZero
migration carries over.

## MEV (BAM)

BAM is the default (`--bam-url`, commission-bps 0). The closest region is scored
by latency in preflight (BAM URL, block-engine URL, and shred receiver are chosen
independently).

> **The BAM / block-engine / shred-receiver tables are point-in-time.** Jito
> rotates the shred-receiver IPs periodically (unlike the genesis hash, which is
> stable for years). Re-verify against
> [bam.dev/validators](https://bam.dev/validators/) and
> [docs.jito.wtf/lowlatencytxnsend](https://docs.jito.wtf/lowlatencytxnsend/)
> rather than trusting the built-in tables forever. `import --rescore` re-pings.

## Upgrades are staked-aware

`deeploy upgrade` checks both the jito-solana and agave release APIs and lets you
**pick/confirm** a tag (it never auto-jumps to latest). It detects the running
identity: if it is **staked**, it warns and **requires an explicit `yes`** — and a
non-interactive (fleet/cron) upgrade **aborts** rather than restart a staked node
(restarting a staked validator skips leader slots; prefer the failover path). The
previous release is kept, so rollback is one symlink flip.

## Private build overlay (advanced)

The public build is **vanilla**. If a patch is present under `private/` (which is
git-ignored), the toolchain runs `git apply --check` against the checked-out tag
and applies it only if that is clean. A patch that is present but does **not**
apply is a hard stop: the build refuses rather than quietly producing a vanilla
binary you believe is patched. Either update the patch for the tag, or move it
out of the overlay directory to build vanilla on purpose. No overlay at all is
the normal public path and stays silent. Nothing about that overlay is in this
repo.

## Failover

The failover suite is a **separate tool**, intentionally not bundled. DeePloy's
exported `deeploy.conf` is reusable by it; install it later via its own one-line
installer.

## Tests

Self-contained, mocked, no live node required:

```bash
./run_tests.sh                                   # every suite; non-zero on any failure
shellcheck -x deeploy.sh run_tests.sh lib/*.sh tests/*.sh     # shellcheck 0.11.0
```

`run_tests.sh` is used instead of a `for` loop on purpose: a loop reports the exit
status of the *last* suite, and a suite that dies mid-run prints no `RESULT` line
at all, so a naive tally counts it as zero failures. The runner treats a suite as
passing only if it exits 0 **and** prints its `RESULT` with no failures.

## References

- Agave releases — https://github.com/anza-xyz/agave/releases
- Jito-Solana releases — https://github.com/jito-foundation/jito-solana/releases
- Jito on-chain addresses — https://jito-foundation.gitbook.io/mev/mev-payment-and-distribution/on-chain-addresses
- Jito low-latency txn send (shred receivers) — https://docs.jito.wtf/lowlatencytxnsend/
- BAM validators — https://bam.dev/validators/
- DoubleZero setup — https://docs.malbeclabs.com/setup/

---

## Status & known limitations

DeePloy is a **release candidate**. The full cycle — install → `catchup 0` →
manual key swap → DoubleZero — was proven end to end on two production boxes
(`bnxt_en` and `mlx5_core`) in June 2026. **Nothing since that run has been
executed on hardware**, the revision you are reading included: the code has
moved on considerably since, on the full-cycle path itself as much as
anywhere. Every release candidate so far has carried that caveat and this one
carries it too. What follows is an honest list of what is *not* proven. Read
it before you point this at a box that matters.

- **The 4.2 client bump is the sharpest instance of that.** Agave 4.2 inverted
  the AF_XDP default from opt-in to opt-out, so the generated `validator.sh` had
  to change on a path that *was* hardware-proven. The new form is covered by
  tests and by reading the upstream source — but it has not yet run on metal.
- **`upgrade` is beta.** It is exercised by tests, not by a real client upgrade
  on a staked box. Treat it as such.
- **DoubleZero passport signing invokes a third-party binary.** `dz-connect`
  passes your staked keypair path to `doublezero-solana`, installed from an apt
  repository and not pinned by DeePloy. It is the one place where a key file is
  handed to software this repository does not control. If that trade-off is not
  acceptable to you, skip DoubleZero — everything else works without it.
- **Disk eligibility is validated on our topologies only.** The disk phase shows
  a table and requires a typed `yes`, but hardening for unusual layouts (a
  mounted non-OS NVMe carrying `/var` or `/home`, exotic RAID) is still open.
  **Read the proposed table before you type `yes`.**
- **The `mlx5` IRQ map is static**, not computed from the running topology.
- **No warranty.** You are responsible for your keys, your stake, and your slots.

Issues and findings are tracked in the repository; security reports go to the
address in [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).

---

Created and maintained by [zimone91](https://github.com/zimone91).
