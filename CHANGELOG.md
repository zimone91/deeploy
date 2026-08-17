# Changelog

All notable changes to DeePloy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and DeePloy adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
