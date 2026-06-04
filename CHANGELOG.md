# Changelog

All notable changes to DeePloy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and DeePloy adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-31

First tagged version: an interactive, idempotent installer that deploys, tunes,
and upgrades an Agave + Jito-BAM Solana mainnet validator on a fresh EPYC box to
`catchup 0`, ready for a manual staked-key swap.

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
