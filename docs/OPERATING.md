## Commands

```
deeploy.sh install        # the phased deploy (resumable, --dry-run-able)
deeploy.sh upgrade        # rebuild to a new tag; keeps the previous for rollback
deeploy.sh upgrade --rollback   # flip active_release back to the previous release
deeploy.sh verify         # run the post-install verification block on demand
deeploy.sh export         # write deeploy.conf (paths/pubkeys/settings only)
deeploy.sh import         # load deeploy.conf into state (import --rescore re-pings region)
deeploy.sh dz-connect     # DoubleZero connect: passport + ibrl + multicast (run AFTER the manual staked-key swap)
deeploy.sh dz-connect --dz-signature <sig>   # offbox: the passport signature, made where the staked key lives
```

Flags: `--dry-run`, `--resume`, `--only <phase>`, `--force`, `--yes`,
`--config <path>`, `--rescore`, `--rollback`, `--dz-signature <sig>`.

## Config (`deeploy.conf`)

A single bash-env file (see [`deeploy.conf.example`](deeploy.conf.example)) holding
**paths, pubkeys, and settings only — never key material**, `chmod 600`.
`deeploy export` writes it; `deeploy import` validates it (and **refuses any file
that contains embedded key material**) before loading it. This is the
"reproduce an identical box without re-typing" path — and what a DoubleZero
migration carries over.

`install --only 6` regenerates `validator.sh` from these settings, so a value
edited into `validator.sh` by hand is lost there; set it in the conf instead.
`MAX_LOCAL_SNAPSHOT_AGE` (default 10240 slots, two incremental intervals) is how
far a local snapshot may lag the newest one the cluster offers and still be
loaded at start instead of downloading one. Too small, and a restart refuses its
own snapshot and goes to the network for one (with 4000, on 2026-10-13, that
download looped). Too large, and the node can start from a snapshot so far
behind that every missing slot has to come in through repair. On 2026-10-19 a
restart 1960 slots behind loaded its own snapshot and caught up in about 9
minutes. It must exceed `INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS` (default 5120), or
the render refuses.
