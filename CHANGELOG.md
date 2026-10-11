# Changelog

All notable changes to DeePloy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and DeePloy adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-rc10] - 2026-10-11

0.1.0-rc9 ran on one mainnet box on 2026-10-05: from its release tarball,
`install --dry-run`, then an install from phase 0 to `catchup 0` on the
throwaway identity, `verify`, `upgrade --dry-run`, an `upgrade` that applied
a private overlay, and `verify` again. On 2026-10-06 the staked key was
swapped in by hand, hot: the old validator's tower was copied over and the
key was fed on stdin over ssh to `set-identity --require-tower`. The box has
voted as that validator since. On 2026-10-08 it was connected to DoubleZero
by hand with the `doublezero` CLI, not with `dz-connect`: IBRL, then
multicast as a publisher of `edge-solana-shreds`. Whether its shreds reach
that group was not measured. The fixes below come from that run and from
reading the code around it.

None of the changes in this release has been executed on hardware.

### Fixed
- **`upgrade` asks the node which identity it runs on.** The guard before a
  restart read `--identity` from the process's command line, and that always
  names the sync identity: `set-identity` swaps the key at runtime. Measured
  on 2026-10-05: after a `set-identity`, the guard printed the sync pubkey
  while `getIdentity` returned another key. A process whose command line could
  not be parsed was let through, and `upgrade --rollback` restarted solana
  without the check. The guard now asks `getIdentity` on the local RPC before
  the build, again right before the restart, and in `--rollback` before the
  release is switched. A validator that is not running, and one on the sync
  identity, pass without a prompt. The staked key, an unknown key, and a
  running process that gives no answer need a typed `yes`, which a run
  without a terminal refuses. `upgrade` no longer reads the staked keypair
  file.
- **The printed key swap moves the tower with the identity.** The swap steps
  said "No tower transfer needed"; see the correction below. Phase 5 and the
  final summary now print the hot swap with the tower. The old validator stops
  voting first, and a restart of it must come back unstaked: its startup
  `--identity` points at the unstaked key, and failover automation is off. Its
  `tower-1_9-<staked-pubkey>.bin` is copied to this box's ledger, and the
  vote-history file too once the vote account has Alpenglow votes. Then
  `set-identity --require-tower`, which refuses without the tower, and
  `authorized-voter add`. A cold bring-up is printed with its condition: the
  old validator stopped, and the cluster's finalized slot at least 300 slots
  past the vote account's `lastVote`. `docs/KEY-MODEL.md` point 3 says the
  same.
- **The build's tag is checked before phase 3 erases disks.** The 0.1.0-rc9
  entry lists this as a known issue. Phase 3 now starts, while the build is
  still ahead, by checking the jito tag: its form, the version floor, and that
  it exists both in the jito-solana repository and as an Anza CLI release for
  its Agave base. A tag that does not exist, and a tag whose existence could
  not be checked, are refused before phase 3 changes anything.
- **A data disk without a filesystem UUID no longer leads to a ledger on the
  system disk.** When `blkid` gave no UUID for a data disk, phase 3 wrote no
  fstab line for its mount point and said nothing. `mount -a` then left the
  point a plain directory on `/`, and the data directories were created and
  recorded there. agave creates a missing ledger directory itself, so the
  validator would have written its ledger to the system disk. An empty UUID
  now refuses before its fstab line is written, and after `mount -a` each
  mount point must be mounted from its own device before the data directories
  are created under it or their paths recorded. A data RAID array mounted
  somewhere else is refused; it used to be a warning.
- **The emergency layout and a RAID0 array that carries `/` ask before the
  ledger goes on the system volume.** Both put the ledger, accounts and
  snapshots under `/root/solana` on the system volume without a question.
  Both now ask for a typed `yes`; `--yes` does not answer it, and without a
  terminal the run refuses. A box laid out on data disks refuses instead, and
  the refusal says how to clear the record for a deliberate re-layout. The
  record is a new state key, `data_layout`, written only by the data layouts
  after their mount check, and not exported. On a box laid out by 0.1.0-rc9
  or older, phase 3 done with the accounts path on a data mount counts as
  laid out.
- **A laid-out box whose data filesystems are not mounted is not a first
  install.** Phase 3 took nothing mounted at `/mnt/accounts` and `/mnt/ledger`
  for a first install. On a box laid out on two data disks that happens when
  neither filesystem mounts at boot (`nofail` lets the boot go on) or someone
  unmounted both; with both disks there, the disk menu offered them, the one
  with the ledger included, and then asked to erase. Phase 3 now checks the
  record before the disk menu and any question about the disks: such a box
  refuses, says what to mount, and says how to clear the record for a
  deliberate re-layout. A box laid out on a data RAID array refuses the same
  way when `/mnt/data` is not mounted.
- **A dry-run plans with what earlier phases decided.** It wrote no state, so
  on a fresh box later steps read defaults instead of what earlier ones had
  decided. Measured on 2026-10-05: a dry-run planned no XDP cores on an mlx5
  NIC with zero-copy, left DoubleZero's packages and firewall rules out after
  a "y", and refused in phase 6 because the region scan's answer was lost.
  Phase 1 also limited ufw to port 22, the port sshd was still on, after a
  move to another SSH port was planned. A dry-run now keeps its state in a
  temp dir under `$TMPDIR`, or `/tmp`, reads it before the real state, never
  writes the real state, and removes the temp dir on exit; if it cannot make
  one, it refuses. It asks phase 1's "Proceed with SSH port change" question
  as a real run does, and on a yes plans ufw and the fail2ban jail for the
  new port. A full dry-run ends at the reboot question, as a real run does; a
  yes prints `[dry-run] systemctl reboot`. It still reads the network: phase
  0's genesis check and region probe, the bandwidth probe with `--net-test`,
  and the tag check. It no longer reports the sysctl files it plans as
  missing.
- **The performance governor holds on every CPU.** cpufrequtils, a base
  package, sets the CPUs' governor at boot; on that box, with no
  `/etc/default/cpufrequtils`, it set ondemand. Nothing ordered it against
  `performance-tweaks.service`: after a reboot on 2026-10-05, 32 of 48 CPUs
  were on ondemand, the PoH core and an XDP core among them. Phase 2 now
  leaves exactly one `GOVERNOR="performance"` line in
  `/etc/default/cpufrequtils` and keeps the file's other lines, and
  `performance-tweaks.service` runs after cpufrequtils. `verify` read cpu0
  only; it now reads every CPU with a cpufreq governor and names the ones
  that are not on performance.
- **mlx5: no IRQ of the NIC stays on an isolated CPU.** The IRQ script carried
  a map written for one CPU layout. On 2026-10-05 it left `mlx5_comp34` on
  CPU 34, the PoH core's SMT sibling, at 259.7 IRQ/s, and on a dual-port card
  it could take the other port's IRQ. The map is now computed at boot from the
  kernel's isolated set: every IRQ of the default-route NIC whose effective
  CPU is isolated, XDP cores included, moves round-robin to a non-isolated CPU
  other than CPU 0, which keeps `mlx5_comp0`. IRQs are matched by the NIC's
  PCI address. `verify` warns on any IRQ of that NIC on an isolated CPU.
- **XDP gets its huge pages.** Each XDP queue asks for 2 MiB huge pages for
  its UMEM and falls back to regular pages with a warning. None were reserved:
  on 2026-10-05 every start logged "huge page alloc failed, falling back to
  regular page size" once per XDP queue. With XDP on, phase 2 now sets
  `vm.nr_hugepages` in `/etc/sysctl.d/21-agave-validator.conf` to twice what
  the XDP queues map, counted from the NIC's ring sizes: 32 for two XDP cores
  with rings of 1024/1024. `verify` checks `HugePages_Total`, and the fallback
  line since the validator's last start.
- **The catchup waits report while the node is behind, and can time out.**
  The phase 8 wait, `verify` and `wait_and_pin_poh.sh` each took the first
  line of `solana catchup --our-localhost`. Once the node's RPC answered,
  that command printed nothing through a pipe until the node had caught up,
  so each blocked in that one call and the 3600 s timeout could not fire: on
  2026-10-05, with the node 190 slots behind, it printed nothing in 30 s.
  They now make two `getSlot` calls at "confirmed", the cluster's from the
  public RPC and then the node's, each capped at 5 s, and log a line on every
  poll. A node at most 4 slots behind counts as caught up. `solana catchup`
  accepts at least that lag: up to 4 at the 400 ms target slot time, about 6
  at the 268.8 ms per slot measured on mainnet on 2026-10-05, and about 8 at
  the roughly 218 ms per slot measured there since 2026-10-09. In the 26
  "has caught up" lines of 2026-10-05 and 2026-10-06 the node was at most 3
  slots behind.
- **`dz-connect` says what the passport request did.**
  `doublezero-solana passport request-validator-access` (0.5.12, the version
  on that box) exits 0 and sends nothing when its own checks fail.
  `dz-connect` then printed "Passport access requested" and waited for a pass
  that could not come; a re-run stopped at the passport while a request was
  pending. It now reads the outcome from the CLI's output: sent only when the
  CLI prints the request's transaction; "Access request already exists" goes
  on to connect; "Errors found:" stops with nothing sent; anything else stops
  as not confirmed and names `doublezero-solana passport fetch
  --access-request` to check before a re-run.
- **A failing probe no longer ends a run before its own message.** Under
  DeePloy's error trap, a check that failed inside a command substitution
  printed a stray `[FAIL] line N`, and in some places ended the run: phase 0's
  port check when `ss` writes after `awk` has exited, phase 0 without
  `/etc/os-release` or where `ethtool -i` does not answer for the NIC, and
  phase 5 when the sync identity or a file at the real-key path cannot be
  read. Each now reaches its own message. In `file` mode an unreadable file at
  the real-key path stops phase 5 with "Could not read a pubkey from the key
  at the real-key path", and says to fix the file or move it off that path.

### Changed
- **`solana-sysctl.service` runs before `solana.service`.** It re-applies
  `21-agave-validator.conf` at boot and had no order against the validator,
  so the two could start side by side. It is ordering only: if the re-apply
  fails, the validator still starts.
- **The release notes count changes since the tree that ran on hardware.**
  `hardware-drift.sh` counted the changes to `deeploy.sh` and `lib/` since
  676be33 (2026-06-15), a lower bound for the last tree run on hardware. Its
  anchor is now 1729f1e, the commit tagged 0.1.0-rc9, which ran on the box
  above. Its comment lists what ran there and what did not.
- **The build time given is the one measured.** The README said "30-90
  min" and `docs/INSTALL.md` "30-90 minutes". On 2026-10-05 the build of
  v4.3.0-jito.0 took 664 s in phase 4 and 712 s in an `upgrade` that applied
  a private overlay, on a box with 48 threads; every run so far was on that
  hardware. Both now say about 11-12 minutes, with that condition; smaller
  machines were not measured. Code and test comments no longer carry a
  number.

### Added
- **An `offbox` mode for the staked key** (`STAKED_KEY_MODE`, asked in phase
  5). `file`, the default, is the behaviour so far. In `offbox` the keypair
  never has to be on the box: DeePloy keeps only its pubkey, checks no path for
  it, and prints the swap as commands that feed the key on stdin over ssh. In
  `dz-connect` you sign the passport message where the key lives and pass the
  signature with `--dz-signature`; the sync identity pays for the request,
  which is simulated first and sent only when the simulation passes.
  `docs/KEY-MODEL.md` lists every read of the key in `file` mode: in
  `dz-connect` it signs the passport message and the request transaction.
- **Phase 5 checks the staked pubkey against the vote account,** where it
  knows the pubkey: a vote account that names another validator identity
  on-chain is a warning. Once the staked pubkey is recorded, `verify` warns
  while the node is not on it.
- **A core dump of the validator carries no heap or stack.** The validator's
  memory holds the identity key. `solana.service` sets `LimitCORE=0` and
  `CoredumpFilter=elf-headers`: with a pipe `core_pattern` the kernel hands a
  core to the helper whatever the limit, and the filter keeps the heap and
  the stacks out of it. Measured on 2026-10-05, before this change: core limit
  0 soft, unlimited hard, and `coredump_filter` 0x33, which includes them.
  `verify` checks both on the running process. A box already installed gets
  the lines when phase 6 renders the unit again, from the next start of the
  validator.
- **`verify` reports BAM connection events** from `solana.log`, unless the MEV
  mode is relayer. In the 10 minutes up to the log's last line, or since the
  validator's start or the log's first line if later, the last event decides:
  established is ok; a loss, a failed connect or an unhealthy attempt is a
  warning. The line also counts the events, and the server's "Challenge
  expired" and "Validator is not on the leader schedule" answers. Measured on
  2026-10-05: 2507 "Challenge expired" in 68 minutes (p50 31.15 ms against a
  30 ms limit), and 845 "Validator is not on the leader schedule" since the
  validator's first start that day. Before the swap the second is expected:
  the proof is signed by the running identity.

### Known issues
- **A dry-run still prints some lines as if it had acted,** such as phase 3's
  "XFS tuning written (…) and applied" and `upgrade --dry-run`'s "Upgraded
  to …".
- **The XDP huge pages are counted once, in phase 2,** from the ring sizes at
  that time; rings changed later need a recount. One NUMA node is the only
  layout measured.
- **On a data RAID array kept as one volume, a `SOLANA_HOME` set outside
  `/mnt/data` takes the ledger off the array.** Phase 3 mounts the array at
  `/mnt/data`, then creates the ledger, accounts and snapshots under
  `SOLANA_HOME`, with no question. `deeploy.conf.example` sets
  `SOLANA_HOME="/root/solana"`, on `/`; with a data RAID array, leave it
  unset.
- **`dz-connect` reports multicast from the tunnel status, not from
  delivery.** With both BGP sessions up and `edge-solana-shreds` in the
  multicast groups, it prints "publishing shreds to edge-solana-shreds".
  Whether shreds reach the group is not checked; on the box above it was
  not measured.

### Correction to 0.1.0 through 0.1.0-rc9
Every release before this one printed in the key-swap steps, in phase 5 and in
the final summary, "No tower transfer needed: a fresh node rebuilds its vote
floor from the cluster." (`lib/start.sh:147`, and in other words
`lib/keys.sh:115`, as of 0.1.0-rc9). The key model said the same, "the safe
path for a first bring-up": in the README through 0.1.0-rc5, and in
`docs/KEY-MODEL.md:18-21` from 0.1.0-rc6. That holds for a cold bring-up only,
with the old validator stopped and the cluster's finalized slot at least 300
slots past the vote account's `lastVote`. In a hot swap the old validator
switches seconds before: its votes that have not landed are missing on the
new node, and their lockouts can be violated. Fixed in this release.

### The correction to 0.1.0-rc8, fixed
The 0.1.0-rc9 entry corrects 0.1.0-rc8: on a box whose system volume is a
RAID0 array, phase 3 could place the ledger and accounts on the system volume
without a prompt. It ends "Not fixed in this release." This release fixes it:
that path now asks for a typed `yes`, and a box laid out on data disks
refuses.

## [0.1.0-rc9] - 2026-10-05

rc8 could not install `v4.3.0-jito.0`, the jito-solana release marked Mainnet:
phase 4 stopped at the Anza CLI download. This release names the Anza CLI
release by the tag's Agave base, refuses a tag that does not have the
jito-solana form, and pins `v4.3.0-jito.0`.

Nothing in this release has been executed on hardware.

### Fixed
- **A jito tag ending in `.N` stopped phase 4.** Phase 4 installs the Anza CLI
  release named by the jito tag's Agave base. It used to strip a trailing
  `-jito`, which leaves `v4.3.0-jito.0` whole, and
  `https://release.anza.xyz/v4.3.0-jito.0/install` is a 404. Phase 4 stopped
  there, after phase 3, which on a two-NVMe layout has already formatted the
  data disks. The base of `v4.3.0-jito.0` is now `v4.3.0`. `--dry-run` returns
  before the download, so it did not show this, and it still does not check
  that the release exists. This is the install path; `upgrade` does not install
  the Anza CLI.

### Changed
- **A tag that does not have the jito-solana form is refused, in `install` and
  in `upgrade`,** before it is recorded or anything is built. The form is
  `vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N]`. A tag without the
  `-jito` suffix used to be only warned about, and the same warning fired on
  `v4.3.0-jito.0`. The jito-solana repository carries bare Agave tags such as
  `v4.3.0`. Such a tag clears DeePloy's version floor on its numbers, and
  Agave's `validator/src` at `v4.3.0` defines none of the Jito-only flags
  DeePloy writes into `validator.sh`: `--block-engine-url`, `--relayer-url` or
  `--bam-url`, the tip and merkle-root flags, `--commission-bps` and
  `--shred-receiver-address`. On a box whose recorded tag has another form,
  `upgrade` now refuses a bare Enter at the tag prompt, where it used to warn
  and rebuild.
- **Pinned client: `v4.2.1-jito` → `v4.3.0-jito.0`,** the latest jito-solana
  release marked Mainnet, in `deeploy.conf.example` and `docs/INSTALL.md`, and
  as the example in the tag prompt of phase 4.
- **`--limit-ledger-size` is deprecated in 4.3.** Per the `v4.3.0-jito.0`
  source, the flag is hidden from `--help` and reported once as a warning at
  startup; its default (200,000,000 shreds) and minimum (50,000,000) are
  unchanged. DeePloy keeps passing it because `--limit-blockstore-size` does
  not exist in `v4.2.0-jito`, the oldest client DeePloy supports. Not yet
  observed on hardware.

### Known issues
- **The tag is still checked in phase 4,** after phase 3 has formatted the data
  disks on a two-NVMe layout. A tag of the wrong form now stops there with a
  refusal. A tag of the right form that does not exist still stops at the
  Anza CLI download or at the jito-solana checkout.

### Correction to 0.1.0-rc8
The 0.1.0-rc8 entry says "A box laid out on data disks never falls back to the
system disk." and "If the recorded layout is `two-nvme` or `raid-volume` and no
eligible data disk is visible, the run refuses and changes nothing." Phase 3
reaches that refusal only when `/proc/mdstat` lists neither a RAID0 array nor
an array that the system is not on and whose members are all NVMe. It asks
about the second kind first (`lib/disk.sh:377-378`). When there is none and no
data disk is eligible, it uses the first RAID0 array listed as a single volume
(`:382-384`), in the branch before the refusal (`:385-396`), and that array can
be the one the system itself is on (`:170`). In that case the ledger and
accounts are placed under `/root/solana` on the system volume (`:360-363`,
`:540-550`), with a warning and no prompt. Only a box whose system volume is a
RAID0 array can be affected. Line numbers are as of 0.1.0-rc8; `lib/disk.sh` is
unchanged in this release. Not fixed in this release.

## [0.1.0-rc8] - 2026-09-23

One check rc7 added refused too much, and one check that was never there let
an install destroy data. Both were found by reading the code, not by a box
failing.

Nothing in this release has been executed on hardware.

### Fixed
- **Phase 0 no longer demands packages phase 1 can install.** It refused to
  start without `mdadm`, `mkfs.xfs`, `setcap` or `getcap`. Phase 3 does need
  `mdadm` and `mkfs.xfs` after the disks are erased and phase 4 needs
  `setcap`/`getcap`, but phase 1 runs first and installs the base packages, so
  it could have installed all of them — and `mdadm` was required even on a box
  whose data disks are not in an array. Phase 1 now installs `xfsprogs`,
  `mdadm` and `libcap2-bin`. The assertion stays; what changed is when absence
  is a refusal. Before phase 1 has run it is expected and the run continues,
  naming what phase 1 will install. Once phase 1 is marked done it means the
  install did not happen, and the refusal returns pointing at
  `install --only 1`, which covers a resume whose phase 1 was completed by a
  version that did not carry these packages.
- **A mounted data disk is refused at three points, not unmounted at one.** An
  NVMe that passed the other checks — at least 400 GB, not part of a data
  array — and was mounted anywhere other than `/`, `/boot`, `/boot/efi`, swap
  or the filesystem holding the checkout was offered for erasure; phase 3
  printed a warning just before the confirmation prompt and, on `yes`,
  unmounted it and erased it. A warning that arrives in the same breath as the
  prompt is not a gate. The menu does not offer such a disk, the backstop that
  validates a disk named in a config file refuses it, and the erase itself
  refuses a disk that is mounted, where the automatic `umount` used to stand.
  `--yes` answers none of them: the menu does not ask, and the other two are
  failures rather than prompts. This is older than rc7 and rc7 did not touch
  it — `_disk_wipe_report`, `_disk_umount_if_mounted`, `_disk_subtree_has_system`
  and `_disk_two_nvme` are byte-identical in rc2, rc3, rc5, rc6 and rc7.
- **A re-run is recognised before any disk is classified.** "Which disk may be
  erased?" and "is this our own box again?" are different questions, and
  answering the first one first was wrong. If `/mnt/accounts` and `/mnt/ledger`
  are both mounted, the devices are taken from those mounts — each must be a
  whole non-system NVMe carrying XFS, and the two must differ — the layout is
  adopted, and nothing is classified, offered or erased. One mounted without
  the other, a partition, a bind mount, the wrong filesystem or both on one
  device each refuse with the reason rather than guessing.
- **A re-run can no longer cross the two mount points in `/etc/fstab`.** This
  one reached real releases. `_disk_finalize_two_nvme` writes fstab keyed by
  MOUNT POINT, so `ensure_line` replaces that mount's line with whatever disk
  the menu answer named. A re-run asked the menu again, and answering in the
  opposite order left `/mnt/accounts` carrying the ledger's UUID and
  `/mnt/ledger` the accounts UUID — to take effect at the next boot, on
  filesystems that were never erased. Measured on a fixture. Taking each device
  from the mount it is actually on cannot produce it.
- **A box laid out on data disks never falls back to the system disk.** The
  emergency layout writes no filesystem, but it rewrites `solana_home`,
  `ledger_path`, `snapshots_path` and `accounts_path` through
  `_disk_record_paths`, so a validator would come back pointed at
  `/root/solana` with its real ledger on a disk nothing references. If the
  recorded layout is `two-nvme` or `raid-volume` and no eligible data disk is
  visible, the run refuses and changes nothing. A first install, and a box
  already recorded as emergency, are unaffected.

### Added
- **Every release page states how much of it has never been on hardware, and
  the figure is computed.** `hardware-drift.sh` reports the files and lines
  changed in `deeploy.sh` and `lib/` since the last tree known to have run on
  metal, naming the commit it measures from and its date, and saying that the
  commit is a lower bound rather than the run itself. The release workflow
  refuses to compose notes if the figure cannot be produced.
- **Every version literal a stranger can act on is checked on every push.** The
  README's install commands, `get-deeploy.sh` (including the usage examples in
  its header) and the worker's default must all equal `v$DEEPLOY_VERSION`. The
  same comparison existed, but only in steps that run on a tag — after the
  irreversible move. The worker's default is read by running the module, not by
  grepping it. Its error-message example had been naming `v0.1.0-rc6` for two
  releases; the new suite found it on its first run.
- **Two known limitations that were true and unlisted** are in the README: the
  build fetches and executes rustup-init and the anza installer, clones
  jito-solana at a tag that can move and the XDP helper with no pin at all, all
  as root and without checking a checksum or a signature; and
  `upgrade --rollback` does not reach the staked-identity guard.

### Changed
- **The test aggregator could finish green having measured nothing.** Its guard
  for a suite that never reported was keyed on `grep` returning empty, and an
  inverted `grep` never returns empty. The result line is now found and parsed
  by bash itself, and a run that ends green with zero assertions is refused.
- **CI enumerates what it checks from `git ls-files`** rather than from a
  hand-written list of paths, and every checkout fetches the full history
  because the suites now measure against it.

### Development note
The mounted-disk refusal was first written to apply before the re-run was
recognised, which made a re-run of an already-installed box fall through to
the emergency layout. That was caught on `main` and fixed before this
release; no published release ever carried it.

## [0.1.0-rc7] - 2026-09-21

`deeploy.sh` had never carried its executable bit. `git archive` packs tracked
files and preserves index modes, so every release tarball unpacked it 100644 and
the README's own first command after `cd` gave `Permission denied`. That was the
mild half. The install writes a systemd unit whose `ExecStart=` is that same
path, `systemctl enable` does not look at the bit, and the failure therefore
lands at the reboot as `status=203/EXEC` — after the disks have been erased and
after the 30-90 minute build. The June hardware runs completed, so the bit was
set by hand on those boxes and never recorded.

Fixing the bit took one commit. The rest of this release is the question that
followed it: what else does the install depend on that nothing checks, and which
of those failures land after the point of no return.

### Added
- **Tools the install needs after the disks are erased are asserted in phase 0.**
  `mkfs.xfs` was invoked one line after `blkdiscard`, came in no package DeePloy
  installs, and was verified nowhere; a box without `xfsprogs` lost both data
  disks and then died on "command not found". The list is derived, not
  remembered: CI re-derives it from the `run()` call sites in every module at or
  after the point of no return and fails when it differs. It also asserts the
  phase ordering the two subtractions rest on, rather than assuming it.
- **The disk holding the checkout is never offered as a wipe target.** A clone
  onto a spare data NVMe passed every filter — not a system disk, is NVMe, over
  the size floor — and phase 3 would have erased the installer mid-run. Resolved
  the way system disks already were, by mount point through `lsblk` holders, so
  RAID and LVM come for free. Every way of not knowing is a refusal: no
  `findmnt`, no answer, or no `DEEPLOY_DIR` each stop the run.
- **The generated `grub.cfg` is read back before any reboot is armed.**
  `grub-mkconfig` sources `/etc/default/grub.d/*.cfg` after `/etc/default/grub`,
  so a drop-in that assigns `GRUB_CMDLINE_LINUX_DEFAULT` replaces the CPU
  isolation DeePloy just wrote while `update-grub` still exits 0. Phase 0 warns
  about such drop-ins, naming the ones on your box; phase 2 refuses if the
  isolation is not in the generated file. Not finding a `grub.cfg` is also a
  refusal — the path depends on BIOS or EFI, so an empty search is an unanswered
  question, not a check that does not apply.
- **A non-executable entry point is refused twice.** In phase 0, where the
  question costs nothing, and again at the reboot boundary, because the bit can
  be lost between them. Neither replaces the gates: those read this repository
  and cannot see a checkout someone unpacked with a umask of their own.
- **Gates that carry the controls proving they can go red.** Every
  documented `./x.sh` must be executable. Every `ExecStart=` that points into the
  checkout must name an executable file, with the claim that the others are
  generated at 0755 asserted rather than written down. And every in-page link
  must point at a heading that exists — which the removal of this release's own
  known-issue section would otherwise have broken silently.

### Changed
- **The root-execution surface is the whole surface.** The checkout check asked
  about the directory and `deeploy.sh`; the boot-time unit runs `deeploy.sh` as
  root and `deeploy.sh` sources every module first. A writable `lib/disk.sh` was
  the same root-persistence vector, one directory down. Globbed, never listed.
- **The README test badge is derived.** It had drifted to 19 against 20 suites on
  disk. A suite counts the files now — the first version of that check lived in
  the workflow, pulled every digit out of `tests-22%20suites`, found the 20
  inside the encoded space, and went red on a badge that was correct.

### Fixed
- `deeploy.sh` is `100755` in the index, so the tarball ships it executable.

## [0.1.0-rc6] - 2026-09-18

Packaging and presentation. The deployment logic, the gates around destructive
steps and the key model are untouched: the tree that deploys is the tree rc5
shipped. What changed is how you get it, how you check what you got, and how
much of the front page you have to read before you know what this does.

### Added
- **`get-deeploy.sh` and a one-command install.** It fetches the pinned release,
  checks the tarball against its `SHA256SUMS`, unpacks, hands the checkout to
  root, and stops. It never runs `deeploy.sh`. Two places a bootstrap is usually
  unsafe are closed: no hash tool means it refuses rather than skipping, and
  `DEEPLOY_INSTALL_TAG` is validated in the script and not only in the route
  that serves it.
- **`worker/index.mjs` and `wrangler.toml`** — the `zim.one/deeploy` endpoint as
  files rather than dashboard clicks. The worker holds no install logic: it
  serves `get-deeploy.sh` from this repository at the tag in the URL and
  prepends one line pinning the version, so the one-liner and the file you read
  are provably the same bytes.
- **`tests/test_bootstrap.sh` and `tests/test_worker.sh`** — 19 suites now. The
  bootstrap suite mocks with executable stubs on a restricted PATH, because the
  subject is a separate `sh` process and a shell function does not cross that
  boundary. `test_worker.sh` requires node and fails without it instead of
  reporting a skip.
- **`docs/`** — six files carved out of the README, moved byte for byte.
- **`.github/` templates and `CODEOWNERS`.** The PR checklist asks for a test
  that fails on the old code, a truthful `--dry-run`, no real identifiers,
  destructive behaviour unchanged or declared, the corrected claim grepped
  across the tree, and which platform the gate was run on.
- **Release notes that verify two different things.** The tarball against its
  manifest catches a damaged download; `get-deeploy.sh` against the digest
  published in the notes is the one check that speaks to provenance, because the
  bootstrap arrives over a different channel. That digest is computed by the
  workflow, never typed.
- **Four new CI gates**, each replacing something that was previously a line in
  a checklist: the bootstrap's default tag must equal the tag being released,
  the worker's default tag must too (determined by importing and running the
  worker, not by grepping its source), the tag must match the pattern both
  consumers accept, and the README must not link a file `git archive` will not
  ship.

### Fixed
- **Three false claims on the README front page.** "Nothing of DeePloy runs
  afterwards" — five units of its own run at every boot, and
  `deeploy-resume.service` is left enabled after a manual `install --resume`.
  "It does read the keypair file, twice" — five reads across three commands.
  "What you need: validator-grade hardware" — the numbers exist and describe
  what this was proven on, not a minimum.
- **Every hand-maintained count.** The test badge carried `1117 across 17
  suites` and was wrong five times inside this batch alone; it carries the suite
  count now. The same number lived in the README feature list and in the CI job
  name. The verify section's `# 44 files` is gone, replaced by what the reader
  is actually looking for in that listing.
- **Release notes no longer call a published release a draft.** The word was
  left over from when the workflow always created one. It is derived from the
  tag now, so a fixed "Release candidate" cannot become the same lie one version
  later.
- **`get-deeploy.sh` pins `LC_ALL=C`.** Bracket ranges are resolved by collation,
  so under bash 3.2 in a UTF-8 locale an accented character passed the tag check
  that guards a string bound for a URL.
- **The worker copies bytes, not text.** `Response.text()` strips a BOM and
  turns invalid bytes into U+FFFD, silently, into a body that is piped into a
  shell. It also reads the body inside the try, validates the path before
  redirecting, and logs the reason for a 502.
- **`mkbin` refuses to build a sandbox it cannot build correctly** — a tool that
  is missing, or a name that resolves to a builtin rather than a path, now fails
  the suite instead of producing a PATH quietly short one tool.

### Conventions
- The rule "grep the whole tree when you correct a claim" now says where it
  stops. CHANGELOG entries record what was true at a point in time; editing one
  into agreement with the present destroys the only question it answers.

### Notes
- The `zim.one/deeploy` worker is deployed after the tag, not before. It serves
  `get-deeploy.sh` by tag, so until the tag exists there is nothing to serve and
  debugging runs against an absent file.
- Green on one platform is not green. A sandbox PATH without `gzip` passed on
  macOS and failed on ubuntu, because `tar -xzf` is one process under BSD tar
  and two under GNU tar.

## [0.1.0-rc5] - 2026-09-16

The public-release cut: the front page, the honest limitations list, and the
release machinery needed to publish an artifact anyone can verify. No change to
the deployment logic — the tree that ships is the tree rc3 tested.

### Added
- **README front page for a public repository** — a centered header with status
  badges (CI, test count, `shellcheck`, release-candidate status, latest
  release, licence) and a "What it does" list, so the first screen answers what
  this is and whether it is maintained.
- **"Verify what you downloaded"** — how to check a release tarball
  (`sha256sum -c`, `tar tzf`), what is pinned in the supply chain (actions by
  commit SHA, `shellcheck` 0.11.0 sha256-verified, a secret scan over the full
  history), and the caveat that a checksum proves integrity, not provenance.
- **"Status & known limitations"** — what is *not* proven: the 4.2 client bump
  has not run on metal, `upgrade` is beta, `dz-connect` hands a keypair path to
  a third-party binary DeePloy does not pin, disk eligibility is validated on a
  limited set of layouts, the `mlx5` IRQ map is static, no warranty. It is
  placed where someone about to run this as root will see it.
- **`workflow_dispatch` on the release workflow.** A tagged release can be
  rebuilt without deleting and re-pushing its tag. The tag comes in as an
  input, the tree is checked out from that tag, and the version gate still
  decides whether the build may proceed — so a rebuild cannot attach one tag's
  tarball to another tag's release. A release that is already published is
  refused outright.

### Fixed
- **CONTRIBUTING no longer claims tags are GPG-signed.** They are annotated and
  unsigned; the README now says so plainly, and the two documents would
  otherwise have contradicted each other in public with the wrong one making
  the stronger promise. Signing remains a separate, later task.
- The README test-count badge is recorded as hand-maintained, so a change in
  suite or assertion counts updates it in the same commit instead of drifting
  silently.
- **One honest staked-key claim everywhere it is made.** Four places said
  DeePloy "will not touch" / "never touches" / "never reads" the staked key —
  the README front page, the `step()` banner in `keys.sh` one line above an
  already-corrected `warn()`, the swap banner in `start.sh`, and the `keys.sh`
  module header, which denied reading the key 87 lines above the code that
  reads it. It does read that file, locally and read-only, in exactly two
  places: to derive the public key, and to sign one DoubleZero passport
  message. All four now say that.
- **The hardware claim is dated instead of implied.** The status section said
  the full cycle "has been proven end to end on two production boxes" and then
  named the 4.2 bump as the one thing unvalidated — which reads as "everything
  else is metal-proven". The run was in June 2026; nothing since, this revision
  included, has been executed on hardware, and the 4.2 bullet is now the
  sharpest instance of that rather than the sole exception.
- **The private-overlay paragraph described the previous release.** rc3 made a
  present-but-inapplicable overlay a hard stop and listed it as breaking; the
  README still promised a warning and a vanilla build. An operator with a
  private patch was planning against behaviour that no longer existed.
- **Two retracted claims that had survived elsewhere**: CONTRIBUTING still
  carried "gzip is not byte-reproducible" after the workflow had retracted it,
  and the release workflow header claimed a "FULL CI gate" it does not run
  (the secret scan lives in `ci.yml`, which the same tag push triggers).
- **README precision pass**: `tar tzf` printed 49 lines beside a comment
  claiming 44; the security-contact line pointed at an address `SECURITY.md`
  does not contain; "a pinned tag" was the shipped config's pin rather than
  anything the code enforces (a floor is); and "no daemons" became what it
  actually means — DeePloy leaves nothing of its own running.

### Conventions
- Commits in this repository carry **no `Co-Authored-By` trailers**, and
  correcting a claim means grepping the whole tree for it rather than the file
  it was noticed in. Both are recorded in `CONTRIBUTING.md`; the second is the
  defect this repository has repeated most often.

### Notes
- This repository's history was rewritten before publication to remove operational
  identifiers from test fixtures. No functional code was changed: the published
  tree is the tree that was tested.

## [0.1.0-rc3] - 2026-08-17

Client version bump to `v4.2.1-jito`, and the compatibility work that bump
forces. Not yet hardware-validated.

### Breaking
- **The minimum supported client is now `v4.2.0-jito`.** Anything older is
  refused at three points — the build (phase 4), `deeploy upgrade`, and the
  phase-6 render — instead of failing at validator start after a 30-90 minute
  build. If your `deeploy.conf` pins an older tag (e.g. `v4.0.0-jito`), the
  install now stops in phase 4 with an explicit message. On a box already
  running an older client: run `deeploy upgrade` to `v4.2.0-jito` or newer,
  then regenerate `validator.sh` (`deeploy install --only 6`).
  The floor is not a preference — the rendered flags below do not exist earlier.
- **A private overlay that does not apply is now a hard stop, not a warning.**
  Previously a patch broken by tag drift was skipped with a warning and the
  build continued VANILLA, producing a binary the operator believed was patched.
  Either update the patch for the new tag, or move it out of the overlay
  directory to build vanilla on purpose. No overlay at all is unchanged: that is
  the normal public path and stays silent.

### Changed
- Pinned client: `v4.0.0-jito` → **`v4.2.1-jito`** (Agave 4.2 is the
  mainnet-recommended line; the 4.2 feature activation has landed).
- The generated `validator.sh` now **always states the XDP decision** —
  `--xdp-cpu-cores` (+ `--xdp-zero-copy`), or `--no-xdp`. Agave 4.2.0 inverted
  the default from opt-in to opt-out, so emitting nothing no longer means
  "disabled": it would silently enable XDP on a box where DeePloy decided
  against it.
- Current flag spellings replace the deprecated `experimental-*` ones:
  `--poh-pinned-cpu-core`, `--xdp-cpu-cores`, `--xdp-zero-copy`. The old names
  still work in 4.2.x but are slated for removal in 4.3.
- `JITO_TAG` is now parsed and validated (`vMAJOR.MINOR.PATCH`); values like
  `latest` or `v4.2` used to be substituted straight into the anza CLI URL.

## [0.1.0-rc2] - 2026-07-02

Server-free hardening: resume reliability, key-invariant enforcement, SSH/GRUB
read-write coherence, and the release mechanics for the public flip. The last
static batch before the next hardware run.

### Security
- The DoubleZero ID migration now **refuses to install the staked validator
  keypair** (pubkey comparison on both copy paths) — closing the one code path
  where the tool itself could duplicate staked key material or register the
  staked pubkey as a DZ ID on-chain.
- The two env-only render vectors are gated fail-closed before they land in
  systemd units: `SOLANA_METRICS_CONFIG` (no shell/unit metacharacters) and
  `DZ_ENV` (strict `mainnet-beta|testnet|devnet` enum).
- The post-reboot resume unit refuses a non-root-owned or group/world-writable
  checkout (a boot-time root-persistence vector) and quotes its ExecStart path.
- Test fixtures use synthetic identifiers (throwaway base58 ids, RFC 5737
  TEST-NET IPs); the internal ops journal (HANDOFF.md) is no longer tracked.
- The private-overlay directory is anchored to the checkout — a run started
  from any other cwd used to silently miss it and build vanilla — and
  `**/mostly_confirmed_threshold` is git-ignored anywhere in the tree.

### Reliability
- A failed DoubleZero restore can no longer kill the post-reboot resume
  service before the validator starts: `fail`/exit inside `dz_resume` is
  isolated in a subshell — warn and continue to phase 8 (the staked node must
  come up unattended even if the tunnel does not).
- `--only` validates its phase (0-8): an unmatched value used to run nothing
  and still print the success banner. `--only`/`--config` without a value fail
  cleanly, and the generated validator.sh header now advertises the runnable
  `install --only 6` form.
- sshd port handling is read/write coherent: the effective port(s) are read
  via `sshd -T` (which sees `sshd_config.d` Include drop-ins) with a file-parse
  fallback; the write leaves exactly ONE `Port` directive; multiple effective
  ports hit an explicit typed-`yes` gate (ignores `--yes`) before any change,
  and the firewall opens every port sshd will actually listen on.
- The SSH verify-or-rollback listener check now requires the listener to BE
  sshd when process info is readable — any daemon parked on the port used to
  pass the check. Port-only fallback when `-p` yields nothing; still
  fail-closed when `ss` is absent.
- GRUB cmdline read/write symmetry: both quote styles are parsed (single-quoted
  provider values used to lose `console=...`), and duplicate
  `GRUB_CMDLINE_LINUX_DEFAULT` lines collapse to one on write.
- The boot sysctl unit runs `sysctl -e -p`: kernels without
  `net.ipv4.tcp_low_latency` (removed in 4.14) or the `westwood` module no
  longer fail the unit on every boot.
- A malformed config now applies **nothing** (atomic parse-then-commit) — the
  "ignoring malformed config" message is finally true.
- `COMMISSION_BPS` is bounded 0-10000 (new `bps` type) at the prompt, the
  config parser, and the render gate.
- `state_set` writes atomically (temp file + rename — a mid-write kill can no
  longer truncate a state entry); the fail2ban sshd jail follows the realized
  SSH port via a `jail.d` drop-in (never clobbering an operator-owned
  jail.local); a missing data mount now fails the phase-8 free-space precheck
  closed (warn + 0 GB) instead of silently skipping it.
- A run lock (`flock`, auto-released on exit) serializes mutating commands: a
  second concurrent `install`/`upgrade`/`import`/`dz-connect` fails fast
  naming the holder; `verify`/`export`/`--dry-run` bypass.
- `performance-tweaks.service` is ordered `Before=solana.service`.

### Tests / CI / Release
- Destructive-path coverage: negative eligibility on an OS-on-NVMe topology
  (the mutation-testing escapee — the system-mount filter now has independent
  negative coverage), the raid-volume destructive path, `require_yes` ignoring
  `--yes`, the preflight hard gate, the `_load_config` trust split, the
  `--only 8` isolation gate driven through the real `start_run`, and an
  `_upgrade_fetch_tags` release-JSON fixture. Suite 843 → 1016.
- CI: least-privilege `permissions`, concurrency cancellation, timeouts, the
  checkout action pinned to a full commit SHA, and a pinned + sha256-verified
  gitleaks full-history secret scan.
- Release mechanics: SECURITY.md (private disclosure, scope, supported
  versions), CONTRIBUTING.md (the gate, per-finding commits, signed tags), and
  a tag-triggered release workflow that re-runs the full gate, builds
  `deeploy-<tag>.tar.gz` + `SHA256SUMS` (the README's verification step now has
  a producer), and creates a draft release. CI asserts the tag matches
  `DEEPLOY_VERSION`, and the integration test derives its version pin from the
  source instead of hardcoding it.

## [0.1.0-rc1] - 2026-06-25

Security & release-hardening pass — the config-execution cluster + safe-static
batch, on top of the audit Sprint-1 + F-series work.

### Security
- **S2** — config files are parsed, never `source`d, at BOTH load sites: a poisoned
  deeploy.conf / `--config` can no longer execute as root. Typed whitelist validates
  every key by type.
- **X1** — the generated `validator.sh` validates + quotes every interpolated value;
  no shell injection via config/state into the root-run start script.
- **X4** — the DoubleZero passport signature is redacted from logs.
- **S3** — restrictive files (the 0600 config) are created private from birth (umask),
  closing a world-readable TOCTOU window.

### Reliability
- **X5** — the SSH-listener verify fails closed when `ss` is unavailable (no silent
  lockout risk on the port change).
- **R9** — removed a module-scope `SOLANA_BIN` pre-seed that shadowed the
  $HOME-independent resolution.
- Fixed a `BASH_REMATCH` clobber in the portrange validator under `set -u`.

### Docs & UX
- Corrected the staked-key safety wording: the key is read read-only to derive its
  pubkey and to sign one DoubleZero passport message — never generated, copied, moved,
  or transmitted. Runnable recovery footer; accurate phase-7 description;
  `--rescore`/`--rollback` documented; `--net-test` wired.

### Tests / CI
- Suite 757 → 843. Added GitHub Actions CI (bash -n + shellcheck + 17 suites).

**Not yet hardware-validated at this HEAD** (pending an on-box run): X2 (disk
eligibility of non-OS mounts), R5/H2 (mount-safety), R2 (bnxt XDP gate), and the
`upgrade` subcommand.

## [0.1.0] - 2026-05-31

First tagged version: an interactive, idempotent installer that deploys, tunes,
and upgrades an Agave + Jito-BAM Solana mainnet validator on a fresh EPYC box to
`catchup 0`, ready for a manual staked-key swap.

### Fixed (real-box, final-run round)
- **Phase 8 start is idempotent — never restarts a running node.** Two paths
  reach Phase 8 (the post-reboot resume service AND a manual `install --resume`);
  the old unconditional `systemctl restart solana` restarted an already-running
  node mid-snapshot-download, throwing away progress (the operator lost ~20%).
  Now `start_enable_service` ADOPTS an already-running validator (systemd active
  + a live `agave-validator` process) and only `systemctl start`s if it isn't
  running — "ensure running", not "restart".
- **Printed commands are runnable.** Summaries/pointers said `deeploy dz-connect`
  / `deeploy export` (incl. the generated `deeploy.conf` header), but there is no
  `deeploy` in PATH. New `DEEPLOY_CMD` (= the absolute `$DEEPLOY_SELF` on a real
  run, else `./deeploy.sh`) is used in all operator-facing text.
- **The old-server gate tolerates dirty input.** Surrounding whitespace no longer
  aborts `dz-connect`: the gate trims, matches the WHOLE trimmed reply strictly
  (y/yes → proceed, n/no/empty → fail), and RE-PROMPTS on anything else
  ("Please answer y or n") instead of failing. It deliberately does NOT take "the
  last token of a phrase" — a conflict-safety gate must never auto-proceed on an
  ambiguous multi-word answer like "maybe y". Still ignores `--yes` (safety
  gate) and still fails non-interactively.
- **`doublezero latency` shows only the nearest devices.** The full table is
  ~150 rows; the display now prints the top `DZ_LATENCY_TOPN` (default 8) by
  lowest avg latency, then the nearest-device line.
- **`doublezero status` polls until BOTH tunnels are up.** The Multicast BGP
  session (`doublezero1`) can lag IBRL's (`doublezero0`); the status display now
  polls up to ~3 min for both to reach "BGP Session Up" instead of snapshotting
  once right after connect, and warns specifically if multicast is still pending.

### Changed
- **DoubleZero work is placed by what it needs.** Principle: the post-swap step
  (`dz-connect`) is MINIMAL — only what genuinely requires the staked key + a
  running node. Everything staked-key-independent happens early, gated on a single
  `dz_enabled` decision:
  - **Phase 1** (with the base system): the single VISIBLE "Enable DoubleZero?"
    prompt (records `dz_enabled` — fixes the earlier invisible redirected prompt),
    package install (`doublezero`+`doublezero-solana`, testnet→mainnet repo swap),
    `-env mainnet-beta` (+metrics, enabled on boot), and ALL firewall in one place
    (core ufw + DZ GRE/BGP/**44880**).
  - **Phase 5** (Keys): a SOFT DZ-ID presence check/reminder — NON-blocking (a
    reboot + staked-key swap come before connect, so there's a window to place it).
  - **Phase 6**: the 2nd shred-receiver address (`233.84.178.1:7733`) is added to
    `validator.sh` iff `dz_enabled` — read from state, no prompt.
  - **Reboot gate**: an early, informational old-server-disconnect reminder.
  - **Phase 7** (install): a no-op pointer to `dz-connect` (prepare already done).
  - **`dz-connect`** (manual, post-swap): HARD DZ-ID migration (mkdir + install to
    `~/.config/doublezero/id.json` + validate) → poll `passport find-validator`
    until in the leader schedule → BLOCKING old-server gate → passport
    prepare/sign/request (Path 1, primary only; the one intentional staked-key
    read) → `connect ibrl` → `connect multicast` (no validator restart — the shred
    address is already in `validator.sh`, live) → two verification displays:
    `doublezero latency` (highlights the nearest device by lowest Avg) and
    `doublezero status` (parses both tunnels, IBRL `doublezero0` + Multicast
    `doublezero1`, and confirms "BGP Session Up" + `P:edge-solana-shreds`).
  `dz-connect`'s guard is `dz_enabled` + binaries actually installed
  (`command -v doublezero`/`doublezero-solana`) + staked-key present — the direct
  binaries-check replaces the retired `dz_prepared` flag (which used to imply
  installation). `dz_resume` is gated on `dz_connected` (no-op until connect ran).
  `dz-finalize` remains a back-compat alias for `dz-connect`. Passport requires
  the validator in gossip + the leader schedule — only true after the manual
  staked-key swap, which is why connect is a separate manual step. Old-server
  reminders (the same DZ ID can't be live on two machines): the informational
  heads-up (reboot gate) + the BLOCKING gate in `dz-connect` before connect
  (ignores `--yes`; fails clearly non-interactively). DeePloy runs no local
  `doublezero disconnect` (a no-op on a fresh box; the disconnect that matters is
  on the old server, which DeePloy can only remind about).

### Fixed
- **DoubleZero is now an interactive prompt, not a silent skip.** It was gated on
  a `DZ_ENABLED` default of `false` overridable only via env/config — an
  interactive operator who left the config alone got no DZ and no question. The
  single "Enable DoubleZero?" prompt (Phase 1, default N) now asks when
  `DZ_ENABLED` isn't explicitly set; env/config still override; `--yes` does NOT
  auto-enable (a tunnel + possible key migration is never set up unattended). The
  decision is recorded to state so later phases read it and the post-reboot resume
  never re-prompts. The single `dz_enabled` decision drives multicast too (no
  separate multicast prompt). (Also fixed a latent bug: the summary pointer keyed
  on `dz_multicast` instead of `dz_enabled`.)
- **Single throwaway identity (was two).** Phase 5 generated both `mvkfake` (the
  sync `--identity`) and a separate `unstaked-identity.json`. Collapsed to ONE
  key — `unstaked-identity.json`, which the node syncs under and which doubles as
  the failover safe-harbor. State var is `sync_identity` (role-based);
  `validator.sh --identity` points to it; the `fake != unstaked` check is gone
  while `vote != identity` and `staked != sync` remain. The `deeploy.conf` key
  stays `UNSTAKED_KEYPAIR` (matches the file name).
- **`solana config` prints once.** `keys_config_cli` made two `config set` calls
  (url, then keypair), each echoing the full config block. Combined into one.
- **DoubleZero ID is always migrated, never generated.** The DZ ID is shared
  across the operator's cluster, so DeePloy never creates one — the operator
  places their existing key. Phase 5 does a SOFT presence check (place it at
  `/root/solana/dz-keypair.json`, or give a path to copy; warns but does NOT block
  — there's a reboot + staked-key swap before connect). `dz-connect` does the HARD
  migration: it installs the key to `~/.config/doublezero/id.json` and validates
  it with `doublezero address`, re-prompting in a loop until a valid key is
  present; a non-interactive run with no key fails with a clear pointer instead of
  hanging. (Earlier drafts had a `DZ_KEY_MODE=migration|fresh` prompt with a
  generate-fresh branch — removed; there is no fresh-generate path.)
- **Environment under systemd is now resolved explicitly (cargo PATH + `$HOME`).**
  Two bugs of one class — env vars present interactively but absent under systemd:
  - *cargo PATH:* `rustup` installs `cargo`/`rustc` to `~/.cargo/bin`; Phase 4
    sourced `~/.cargo/env` only in its own context, so Phase 6's bnxt XDP
    self-check hit `cargo: command not found` (and on `--resume`, Phase 4 is
    skipped, so nothing put it on PATH). New shared `ensure_cargo_env` sources the
    env and puts `~/.cargo/bin` on PATH exactly once; the toolchain build and the
    nic XDP test both call it. The XDP test fails cleanly (`return 1`,
    do-not-start) if cargo is genuinely absent.
  - *empty `$HOME`:* the systemd resume service starts with an empty environment,
    so `SOLANA_BIN="$HOME/.local/..."` collapsed to `/.local/...` and Phase 8's
    catchup-verify loop ran a non-existent path. The resume service unit now sets
    `Environment=HOME=/root` and a full `PATH` (incl. `/root/.cargo/bin`), and
    `SOLANA_BIN` is resolved `$HOME`-free via shared `deeploy_solana_bin` (explicit
    > state-recorded `solana_bin` > `/root` default) in start/verify/keys/
    doublezero/upgrade. `toolchain_install_release` records the absolute bin path
    to state. (The generated `wait_and_pin_poh.sh` already baked an absolute path
    at generation time, so PoH pinning was unaffected.)
- **XFS sysctl no longer aborts Phase 2 on a fresh box.** `fs.xfs.xfssyncd_centisecs`
  was in Phase 2's `/etc/sysctl.d/21-agave-validator.conf`, but `/proc/sys/fs/xfs/`
  doesn't exist until an XFS filesystem is mounted — so `sysctl -p` returned
  non-zero and, under `set -Eeuo pipefail`, aborted the install before Phase 3.
  The XFS tuning now lives in Phase 3 (`disk.sh`), applied after `mkfs.xfs`, via a
  dedicated `/etc/sysctl.d/22-agave-xfs.conf` plus a `modules-load.d` xfs preload
  so it re-applies on every boot (the isolation reboot would otherwise drop a live
  value, and `systemd-sysctl` runs before fstab mounts). Phase 2's sysctl file now
  holds only always-valid kernel/net/vm keys. Belt-and-suspenders: all sysctl
  drop-ins are now applied key-by-key (`apply_sysctl_file`) so any not-yet-present
  key warns and is skipped instead of failing the run.
- **Phase 3 no longer treats system disks as wipe candidates.** System-disk
  detection is now by mount and resolves RAID/LVM to physical members: a disk is
  a *system* disk if anything in its block subtree carries `/`, `/boot`,
  `/boot/efi`, or swap — including through an `md`/LVM holder. Previously a root
  on `/dev/md0` was reduced to the string `"md"`, so the real RAID members (e.g.
  `sda`/`sdb`) slipped through as data candidates and could be proposed for
  erasure. (`require_yes` still blocked the actual wipe, but the proposal itself
  was wrong.)
- **Preflight RAID warning corrected.** A software-RAID *system* volume is now
  reported as normal (its members are excluded; the data disks are the separate
  NVMe) instead of the misleading "Phase 3 will use a single-volume root
  layout". A RAID on non-system disks is reported as what Phase 3 actually does.
  The data-disk count is now RAID-aware and reflects eligible NVMe.

### Changed
- **accounts/ledger candidates must be NVMe.** SATA/SAS disks are shown in the
  storage table for transparency but marked not-eligible and are not selectable
  (random I/O can't sustain a mainnet validator). Two independent filters —
  system-mount AND device-type — so a system disk cannot slip through even if
  RAID detection missed it.
- **Disk picking is a numbered menu** over eligible NVMe instead of free-form
  `/dev/...` entry, so system and non-NVMe disks can't be typed in.
  `_disk_assert_eligible` (not-root + not-system + NVMe) is enforced as a
  backstop even for `--config`-provided paths.
- **Placement strategy, by priority:** ≥2 eligible NVMe → separate
  accounts/ledger volumes; else an existing RAID0 → single shared volume on that
  array (never creates one); else an *emergency* single-disk layout with a loud
  "not recommended for mainnet" warning. If two data NVMe are themselves joined
  in a RAID with the OS elsewhere, the operator is prompted to break it into two
  volumes, use it as one, or cancel.

- **`set -e`/`pipefail` errexit hardening across all phases.** The installer
  runs under `set -Eeuo pipefail`, but two shapes aborted it on real hardware:
  (1) a function whose last statement is a `while read … done` loop returns the
  loop's EOF status (1); (2) a `var=$(pipeline)` where a stage legitimately
  returns non-zero (`grep` no match, `blkid` on an unformatted device, and —
  most importantly — `solana catchup`, which is non-zero the entire time the
  node is syncing). The latter would have killed the post-reboot resume service
  at Phase 8, right where it should be calmly polling. Hardened every such site
  in `start.sh` (catchup poll), `preflight.sh`, `region.sh`, `verify.sh` (all
  probes), `upgrade.sh`, and `doublezero.sh`, plus the disk-detection loops.

### Added
- `DEEPLOY_VERSION` (0.1.0), a `--version` / `-V` flag, the version recorded to
  run-state at the start of `install`, and stamped into the header of
  `deeploy export` output.
- A `set -Eeuo pipefail` harness in the integration test that re-runs the full
  install path under the exact production flags, plus a Phase 8 regression that
  proves the catchup loop polls through a non-zero `catchup` instead of
  aborting — so this whole error class is caught in CI from now on.
- This changelog.
