# Changelog

All notable changes to DeePloy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and DeePloy adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-31

First tagged version: an interactive, idempotent installer that deploys, tunes,
and upgrades an Agave + Jito-BAM Solana mainnet validator on a fresh EPYC box to
`catchup 0`, ready for a manual staked-key swap.

### Changed
- **DoubleZero split into prepare (Phase 7) + connect (`dz-connect`).** Passport
  requires the validator visible in Solana gossip AND the leader schedule, which
  is only true AFTER the manual swap to the staked identity — so the old design
  (connect during Phase 7, on the unstaked sync identity) could never have
  worked. Now Phase 7 does PREPARE only (install with testnet→mainnet repo swap;
  `-env mainnet-beta` + metrics; ufw GRE/BGP/**44880**; place the migrated
  DoubleZero ID at `~/.config/doublezero/id.json`; `doublezero latency`;
  `doublezero disconnect`; enable on boot) — no active networking, never touches
  the staked key. The new `deeploy dz-connect` (run post-swap) polls
  `passport find-validator` until the node is in the leader schedule, runs
  passport prepare/sign/request (Path 1, primary only — this DOES read the staked
  key, the one intentional exception), `connect ibrl`, polls `doublezero status`
  until up, then `connect multicast`. No validator restart (the multicast shred
  address is baked into `validator.sh` at generation and picked up live). The
  2nd shred-receiver address (`233.84.178.1:7733`) is added to `validator.sh` in
  Phase 6 iff `dz_enabled` — the single "Enable DoubleZero?" decision drives both
  the prepare and the shred address; there is no separate multicast prompt.
  `dz-finalize` remains as a back-compat alias for `dz-connect`. Post-reboot
  `dz_resume` now no-ops until `dz_connected` (nothing to restore before connect).
  Old-server reminders (the same DZ ID can't be live on two machines): an
  informational heads-up at prepare (place-the-ID step — plan to disconnect the
  old server) and a BLOCKING gate in `dz-connect` right before `connect ibrl`
  (acknowledge the old server is disconnected; ignores `--yes`; fails clearly
  non-interactively). No local `doublezero disconnect` on the new box (a no-op on
  a fresh box; the disconnect that matters is on the old server, which DeePloy
  can only remind about).

### Fixed
- **DoubleZero is now an interactive prompt, not a silent skip.** Phase 7 gated
  on a `DZ_ENABLED` default of `false` overridable only via env/config — an
  interactive operator who left the config alone got no DZ and no question. Phase
  7 now ASKS ("Enable DoubleZero?", default N) when `DZ_ENABLED` isn't explicitly
  set; env/config still override; `--yes` deliberately does NOT auto-enable
  (a tunnel + possible key migration is never set up unattended). The decision is
  recorded to state so the post-reboot resume neither re-skips nor re-prompts: it
  verifies `doublezero0` came up and, only if not, restores the tunnel from saved
  settings (never re-placing the migration key). Multicast is likewise prompted
  when unset. (Also fixed a latent bug: the dz-finalize summary pointer keyed on
  `dz_multicast` instead of `dz_enabled`.)
- **Single throwaway identity (was two).** Phase 5 generated both `mvkfake` (the
  sync `--identity`) and a separate `unstaked-identity.json`. Collapsed to ONE
  key — `unstaked-identity.json`, which the node syncs under and which doubles as
  the failover safe-harbor. State var is `sync_identity` (role-based);
  `validator.sh --identity` points to it; the `fake != unstaked` check is gone
  while `vote != identity` and `staked != sync` remain. The `deeploy.conf` key
  stays `UNSTAKED_KEYPAIR` (matches the file name).
- **`solana config` prints once.** `keys_config_cli` made two `config set` calls
  (url, then keypair), each echoing the full config block. Combined into one.
- **DoubleZero migration no longer silently generates a new key.** `dz_keypair`
  conflated "key file exists" with "is a migration": if the operator hadn't
  pre-placed their production dz-keypair, DeePloy generated a brand-new key
  (breaking the migration), with no pause to place the real key or to shut
  DoubleZero down on the old server. Now the mode is asked explicitly (default
  *migration*). Migration **blocks** until the existing key is placed at
  `$DZ_KEYPAIR` and validates as a readable Solana keypair (re-prompts in a loop
  if absent/invalid), then gates on confirming the old server is
  disconnected/stopped. *Fresh* refuses to overwrite an existing key. A
  non-interactive run that needs a manually-placed key fails with a clear pointer
  instead of hanging or generating the wrong key. (`DZ_KEY_MODE=migration|fresh`
  overrides the prompt for automation/tests.)
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
