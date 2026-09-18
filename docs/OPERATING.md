## Commands

```
deeploy.sh install        # the phased deploy (resumable, --dry-run-able)
deeploy.sh upgrade        # rebuild to a new tag; keeps the previous for rollback
deeploy.sh upgrade --rollback   # flip active_release back to the previous release
deeploy.sh verify         # run the post-install verification block on demand
deeploy.sh export         # write deeploy.conf (paths/pubkeys/settings only)
deeploy.sh import         # load deeploy.conf into state (import --rescore re-pings region)
deeploy.sh dz-connect     # DoubleZero connect: passport + ibrl + multicast (run AFTER the manual staked-key swap)
```

Flags: `--dry-run`, `--resume`, `--only <phase>`, `--force`, `--yes`,
`--config <path>`, `--rescore`, `--rollback`.

## Config (`deeploy.conf`)

A single bash-env file (see [`deeploy.conf.example`](deeploy.conf.example)) holding
**paths, pubkeys, and settings only — never key material**, `chmod 600`.
`deeploy export` writes it; `deeploy import` validates it (and **refuses any file
that contains embedded key material**) before loading it. This is the
"reproduce an identical box without re-typing" path — and what a DoubleZero
migration carries over.

