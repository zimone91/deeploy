## Hardware & the disk trade-off

Target: a fresh Ubuntu 24.04 x86-64 box (every run so far: 48 threads,
377 GiB RAM, 2× ~1.92 TB data NVMe + a separate system disk).

**Client:** the shipped `deeploy.conf.example` pins `JITO_TAG="v4.3.2-jito"`,
and a bare Enter at the install's tag prompt builds the same tag; a run without
a terminal has to name one. It is also the **recommended** minimum: SFDP
requires Agave 4.3.2 or newer from epoch 1063. A tag below it gets a warning at
the build, the upgrade and the render, and the run goes on. The code enforces a
floor of **v4.2.0-jito**.
Older clients are refused before the build: where XDP is off, the generated
`validator.sh` passes `--no-xdp`, which does not exist before 4.2.0, so an
older binary would go through a whole build (v4.3.2-jito took 724 s on the
hardware above) and then refuse to start. While the build
is still ahead, the tag is checked before the disk phase erases anything: its
form, the floor, and that it exists, both in the jito-solana repository and as
an Anza CLI release for its base. A tag that does not exist, and one that cannot
be checked, are refused there. After the checkout, the pinned tag must be at its
pinned commit: if the tag has moved, the build is refused. Any other tag is
built, and its commit is printed so it can be compared with the release page.

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
| 1 | Base | needrestart drop-in, packages, SSH-port change (verify-or-rollback), core ufw; SSH is rate-limited (`ufw limit`: an address with 6 or more new connections in 30 s is refused) |
| 2 | Tuning | **dynamic isolation of the XDP cores → GRUB**, performance-tweaks, sysctl, NOFILE → reboot gate |
| 3 | Disk | detect → confirm → blkdiscard + mkfs.xfs + mount + fstab + symlink |
| 4 | Toolchain | rustup, anza CLI, build jito-solana @ tag (LTO, `target-cpu=native`), setcap |
| 5 | Keys | generate the unstaked sync identity; ask where the staked key lives (`file` on the box, or `offbox`); print the hot swap |
| 6 | Validator config | generate `validator.sh` (it reports OS stats with its metrics), `solana.service`, logrotate, NIC setup; remove the PoH-pin units of an older DeePloy |
| 7 | DoubleZero | (optional, prompted) PREPARE only: packages, env→mainnet-beta, ufw (GRE, BGP, 44880) + old-server-disconnect reminder + pointer — ID-migration, passport, and connect are the separate post-swap `dz-connect` step |
| 8 | Start | free-disk precheck → start → `catchup 0` → verify → summary |

## CPU isolation

Phase 2 isolates the XDP retransmit cores and their SMT siblings, and nothing
else: the first `XDP_CORES_COUNT` physical cores from CPU 1 up, plus their
siblings. `isolcpus`, `nohz_full`, `rcu_nocbs` and `irqaffinity` go to GRUB.
After `update-grub` phase 2 reads the generated `grub.cfg` back and stops before
the reboot if `isolcpus` or `nohz_full` is not in it; `rcu_nocbs` and
`irqaffinity` are written but not read back. After the reboot the gate compares
`/sys/devices/system/cpu/isolated` with the recorded set and does not start the
validator on a mismatch. With `XDP_CORES_COUNT=0` (no XDP-capable NIC) nothing
is isolated, and GRUB gets only `amd_pstate=passive` and
`nvme_core.default_ps_max_latency_us=0`, which the read-back then checks; the
gate has no set to compare.

CPU 0 is never an XDP core: without `--poh-pinned-cpu-core`, jito-solana
v4.3.2-jito counts CPU 0 as the PoH core (`poh/src/poh_service.rs` 43) and
refuses `--xdp-cpu-cores` that include it (`validator/src/commands/run/execute.rs`
1515-1532).

There is no PoH core to set. After the Alpenglow migration, jito-solana
v4.3.2-jito does not start PohService (`poh/src/poh_service.rs` 121-129), so
there is no PoH thread to pin, and `POH_CORE` is no longer a setting: a
`deeploy.conf` that still has it gets a warning and the line is ignored.

An older DeePloy isolated a PoH core as well and pinned the PoH thread with
`solana-poh-pin`. Re-running phase 2 replaces the old `isolcpus`, `nohz_full`,
`rcu_nocbs` and `irqaffinity` with the new set; the change takes effect at the
next planned reboot. Re-running phase 6 stops and removes the `solana-poh-pin`
timer and service and the two scripts it used, rewrites `validator.sh` without
`--poh-pinned-cpu-core`, and never restarts `solana.service`: the new
`validator.sh` takes effect at the next planned restart (a staked node: move it
to the standby first).

## Library updates and the validator

On Ubuntu 24.04 the APT hook (`/etc/apt/apt.conf.d/99needrestart`) runs
needrestart in automatic mode: `$nrconf{restart}` is unset, and the default for
the hook is `a` (the comment in `needrestart.conf`; `/usr/sbin/needrestart`
264-273, needrestart 3.6-7ubuntu4.5). A library update then restarts the
services that map the old library, except those its configuration defers. The
validator maps libc, libm, libstdc++ and libgcc_s, and on a test box one
unattended upgrade restarted 13 services within a second.

Where `/etc/needrestart` exists, phase 1 writes
`/etc/needrestart/conf.d/90-deeploy-solana.conf`, the one line
`$nrconf{override_rc}{qr(^solana\.service$)} = 0;` with a comment. needrestart
then lists `solana.service` among the restarts it defers and leaves it running;
the other entries of its configuration stay. Without needrestart phase 1 says so
and writes nothing, and `verify` warns if needrestart is installed and the file
is missing.

The rule: restart `solana.service` at a planned time, after a library update
too. A staked node goes through its standby first.

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

## Metrics

The validator's metrics go to mainnet-beta (`metrics.solana.com`) by default. It
is the endpoint Anza's cluster docs give for Mainnet Beta
([docs.anza.xyz/clusters/available](https://docs.anza.xyz/clusters/available)),
and the one Jito's BAM validator guide recommends
([bam.dev/validators](https://bam.dev/validators), step 3, "Enabling Metrics
Collection").
SFDP's metric-reporting check used to read one core metric,
`optimistic_slot.slot`, from that database. Under Alpenglow the validator
no longer sends it: in jito-solana v4.3.2-jito the metric has one source, the
optimistic-confirmation verifier, and the vote listener drops that verifier once
Alpenglow is enabled. SFDP's API, read on 2026-10-22 for one validator, shows
`optimistic_slot.slot` for epoch 1060 and the exemption
`metric-reporting-ignored` for epochs 1062 and 1063.
`METRICS_TARGET="bam"` in `deeploy.conf` sends them to the BAM community
endpoint instead, and `export` carries that choice. `SOLANA_METRICS_CONFIG` in
the environment overrides both.
