## Upgrades are staked-aware

`deeploy upgrade` lists recent jito-solana and agave releases — the agave list is
for reference only — and lets you **pick/confirm** a jito-solana tag (it never
auto-jumps to latest); a tag of any other shape is refused. It asks the running
node for its identity with `getIdentity` on the local RPC, before the build and
again right before the restart: the staked identity is applied at runtime, so the
process arguments always show the sync one. Anything but the sync identity — the
staked key, an unknown key, or no answer while the validator runs — gets a warning
and **requires an explicit `yes`**, and a non-interactive (fleet/cron) upgrade
**aborts** rather than restart that node (a restart brings it back on the sync
identity and skips its leader slots; prefer the failover path). The previous
release is kept, so rollback is one symlink flip, behind the same check.

The tag has the install's floor: below **v4.2.0-jito** the upgrade is refused
before anything is built. Below the recommended **v4.3.2-jito.0** it warns (SFDP
requires Agave 4.3.2 or newer from epoch 1063) and goes on.
