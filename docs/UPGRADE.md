## Upgrades are staked-aware

`deeploy upgrade` checks both the jito-solana and agave release APIs and lets you
**pick/confirm** a tag (it never auto-jumps to latest). It detects the running
identity: if it is **staked**, it warns and **requires an explicit `yes`** — and a
non-interactive (fleet/cron) upgrade **aborts** rather than restart a staked node
(restarting a staked validator skips leader slots; prefer the failover path). The
previous release is kept, so rollback is one symlink flip.

