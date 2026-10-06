## Hardware & the disk trade-off

Target: a fresh Ubuntu 24.04 x86-64 box (built and proven on AMD EPYC,
377 GiB RAM, 2× ~1.92 TB data NVMe + a separate system disk).

**Client:** the shipped `deeploy.conf.example` pins `JITO_TAG="v4.3.0-jito.0"`;
the code enforces a floor of **v4.2.0-jito**. Older clients are refused before
the build: the generated `validator.sh` passes `--no-xdp` and
`--poh-pinned-cpu-core`, neither of which exists before 4.2.0, so an older
binary would build for 30-90 minutes and then refuse to start. While the build
is still ahead, the tag is checked before the disk phase erases anything: its
form, the floor, and that it exists, both in the jito-solana repository and as
an Anza CLI release for its base. A tag that does not exist, and one that cannot
be checked, are refused there.

- **Ideal:** **two separate data NVMe** — `accounts` and `ledger` on *different*
  physical disks. This keeps snapshot packaging and accountsdb writes from
  competing for the same spindle/queue. DeePloy formats them XFS and mounts
  `/mnt/accounts` + `/mnt/ledger` (snapshots ride with the ledger disk).
- **Single disk or RAID:** works, but is **suboptimal** — accounts and ledger
  share one volume, and DeePloy warns and recommends separate NVMe. When that
  volume is the system volume (a single disk, or a RAID0 array that also
  carries `/`), DeePloy asks first and you type `yes`. A box that was laid out
  on data disks is not moved onto the system volume, and is not taken for a
  fresh install when its data disks are not mounted: the run refuses, and says
  how to clear the record if the box really is being laid out again.

The disk phase **detects** your disks, shows a table, proposes a mapping, and
**requires you to type `yes`** before wiping anything or using the system
volume. `--yes`/`--post-reboot` never answer that question.

---

## Phases

| # | Phase | What it does |
|---|---|---|
| 0 | Preflight | root/OS/CPU/RAM/disk/NIC audit, mainnet genesis guard, closest-region scoring |
| 1 | Base | packages, SSH-port change (verify-or-rollback), core ufw |
| 2 | Tuning | **dynamic CPU isolation → GRUB**, performance-tweaks, sysctl, NOFILE → reboot gate |
| 3 | Disk | detect → confirm → blkdiscard + mkfs.xfs + mount + fstab + symlink |
| 4 | Toolchain | rustup, anza CLI, build jito-solana @ tag (LTO, `target-cpu=native`), setcap |
| 5 | Keys | generate the unstaked sync identity; ask where the staked key lives (`file` on the box, or `offbox`); print the hot swap |
| 6 | Validator config | generate `validator.sh`, `solana.service`, logrotate, PoH-pin, NIC setup |
| 7 | DoubleZero | (optional, prompted) PREPARE only: packages, env→mainnet-beta, ufw (GRE, BGP, 44880) + old-server-disconnect reminder + pointer — ID-migration, passport, and connect are the separate post-swap `dz-connect` step |
| 8 | Start | free-disk precheck → start → `catchup 0` → pin PoH → verify → summary |

## MEV (BAM)

BAM is the default (`--bam-url`, commission-bps 0). The closest region is scored
by latency in preflight (BAM URL, block-engine URL, and shred receiver are chosen
independently).

`deeploy.sh verify` reads BAM's connection events from the last 10 minutes of
`solana.log` (from the validator's start or the log's first line, if later).
The last event decides: an established connection is ok; a loss, a failed
connect or an attempt that never became healthy is a WARN. The line also counts
the attempts and gives the server's reasons: `Challenge expired` (by the time
the server checked the signed proof, more than its `max allowed` had passed
since it created the challenge; the elapsed p50 is shown) and `not on the
leader schedule`. The proof is signed by the running identity, so on the sync
identity, before the swap, the second one is expected.

> **The BAM / block-engine / shred-receiver tables are point-in-time.** Jito
> rotates the shred-receiver IPs periodically (unlike the genesis hash, which is
> stable for years). Re-verify against
> [bam.dev/validators](https://bam.dev/validators/) and
> [docs.jito.wtf/lowlatencytxnsend](https://docs.jito.wtf/lowlatencytxnsend/)
> rather than trusting the built-in tables forever. `import --rescore` re-pings.

