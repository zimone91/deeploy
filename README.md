# DeePloy

An interactive, idempotent CLI that deploys, tunes, and upgrades a **Solana
mainnet-beta** validator (Agave + Jito-BAM, built from source) on a fresh server
— from bare box to `catchup 0`, ready for a manual staked-key transfer.

It is written to be **read before it is run as root on a box that will hold real
money**: plain `bash`, modular, no magic, every system file backed up before it's
touched, and a `--dry-run` that prints the whole plan and changes nothing.

---

## ⚠️ Read this first — the staked-key model

DeePloy **never touches your real staked validator key.** Understand the flow
before you run it; this is what separates "fine on testnet" from "I know what I'm
doing on mainnet":

1. DeePloy brings the node up on a **throwaway "fake" identity** and lets it sync.
2. The **real staked key is moved in manually by you**, at the end, with the
   printed `set-identity` commands. DeePloy will not generate, copy, or read it.
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
| 5 | Keys | generate fake + unstaked identities; print where the real key goes |
| 6 | Validator config | generate `validator.sh`, `solana.service`, logrotate, PoH-pin, NIC setup |
| 7 | DoubleZero | (optional) install/keypair/env/ufw/connect ibrl/multicast |
| 8 | Start | free-disk precheck → start → `catchup 0` → pin PoH → verify → summary |

## Commands

```
deeploy.sh install        # the phased deploy (resumable, --dry-run-able)
deeploy.sh upgrade        # rebuild to a new tag; keeps the previous for rollback
deeploy.sh upgrade --rollback   # flip active_release back to the previous release
deeploy.sh verify         # run the post-install verification block on demand
deeploy.sh export         # write deeploy.conf (paths/pubkeys/settings only)
deeploy.sh import         # load deeploy.conf into state (import --rescore re-pings region)
deeploy.sh dz-finalize    # DoubleZero passport access (run AFTER the manual key swap)
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
and applies it only if it's clean — otherwise it logs a warning and builds
vanilla. Nothing about that overlay is in this repo.

## Failover

The failover suite is a **separate tool**, intentionally not bundled. DeePloy's
exported `deeploy.conf` is reusable by it; install it later via its own one-line
installer.

## Tests

Self-contained, mocked, no live node required:

```bash
for t in tests/test_*.sh; do bash "$t"; done
shellcheck -x deeploy.sh lib/*.sh
```

## References

- Agave releases — https://github.com/anza-xyz/agave/releases
- Jito-Solana releases — https://github.com/jito-foundation/jito-solana/releases
- Jito on-chain addresses — https://jito-foundation.gitbook.io/mev/mev-payment-and-distribution/on-chain-addresses
- Jito low-latency txn send (shred receivers) — https://docs.jito.wtf/lowlatencytxnsend/
- BAM validators — https://bam.dev/validators/
- DoubleZero setup — https://docs.malbeclabs.com/setup/

## License

MIT — see [LICENSE](LICENSE).
