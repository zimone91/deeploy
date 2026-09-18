## Hardware & the disk trade-off

Target: a fresh Ubuntu 24.04 x86-64 box (built and proven on AMD EPYC,
377 GiB RAM, 2× ~1.92 TB data NVMe + a separate system disk).

**Client:** the shipped `deeploy.conf.example` pins `JITO_TAG="v4.2.1-jito"`;
the code enforces a floor of **v4.2.0-jito**. Older clients are refused before
the build: the generated `validator.sh` passes `--no-xdp` and
`--poh-pinned-cpu-core`, neither of which exists before 4.2.0, so an older
binary would build for 30-90 minutes and then refuse to start.

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

