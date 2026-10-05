## Upgrades are staked-aware

`deeploy upgrade` lists recent jito-solana and agave releases — the agave list is
for reference only — and lets you **pick/confirm** a jito-solana tag (it never
auto-jumps to latest); a tag of any other shape is refused. It detects the running
identity: if it is **staked**, it warns and **requires an explicit `yes`** — and a
non-interactive (fleet/cron) upgrade **aborts** rather than restart a staked node
(restarting a staked validator skips leader slots; prefer the failover path). The
previous release is kept, so rollback is one symlink flip.

