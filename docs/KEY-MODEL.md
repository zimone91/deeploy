## ⚠️ Read this first — the staked-key model

DeePloy never **generates, copies, moves, or transmits** your real staked
validator key, and never places it on the box for you. The node syncs on a
throwaway identity and you swap the staked key in manually (step 2). Where the
key lives is your choice, made once at install (`STAKED_KEY_MODE`):

- **`file`** (the default): you place the keypair on the box. DeePloy reads it
  read-only, in exactly these places, and never writes, copies, or sends it:
  - phase 5 (keys): it checks whether the file exists, and if it does, derives
    the **public** key, which must not be the sync identity. If you hand it a
    DoubleZero ID to copy, it derives the staked public key again first: a
    DoubleZero ID must never be the staked key.
  - `dz-connect`: it checks that the file exists, derives the public key for
    that DoubleZero-ID check before each attempt to install the ID, and once
    more for the passport's validator ID. `solana sign-offchain-message -k
    <file>` signs the passport message, and `doublezero-solana passport
    request-validator-access -k <file>` loads it as the wallet that signs the
    request transaction and pays for it.

  The solana CLI's default keypair is set to the file's path — a path string,
  not a read.
- **`offbox`**: the keypair never has to be on the box. DeePloy keeps only its
  public key (`STAKED_PUBKEY`). It never reads, pipes, prompts for, or stores
  the key, and checks no path for it. You pipe the key to `set-identity` over
  ssh from the machine that holds it. In `dz-connect` you sign the passport
  message there and pass the signature with `--dz-signature`, and the sync
  identity pays for the request (after a `--dry-run`).

Understand the flow before you run it; this is what separates "fine on testnet"
from "I know what I'm doing on mainnet":

1. DeePloy brings the node up on a **throwaway "fake" identity** and lets it sync.
2. The **real staked key is swapped in manually by you**, at the end, with the
   printed commands: `set-identity` with the keypair path (`file`), or the same
   commands fed the key on stdin over ssh, so that it never touches the box's
   disk (`offbox`). The swap changes the running process only, so in both modes
   any restart of solana — a crash, a reboot, an upgrade — brings the node back
   on the sync identity, and it does not vote until you repeat the two
   commands. `deeploy.sh verify` warns while the node is not on the staked
   identity (in `file` mode, once DeePloy has derived the staked pubkey).
3. **In a hot swap the tower moves with the identity.** While the old validator
   is still running, it stops voting first (`set-identity` to its unstaked key),
   and a restart of it must come back unstaked too: its startup `--identity`
   (argv or symlink) points at the unstaked key, and failover automation is off.
   Otherwise a crash or a restart brings it back staked, and two nodes vote. Its
   `tower-1_9-<staked-pubkey>.bin` is copied to this box, and `set-identity
   --require-tower` refuses to take the identity without it. Without the tower,
   votes the old node cast that have not landed are unknown here, and their
   lockouts can be violated. After Alpenglow activates, the vote-history file
   travels with the tower. A **cold bring-up** needs no tower: when the old
   validator is stopped and the cluster's finalized slot is at least 300 slots
   past the vote account's `lastVote` — a margin for a vote that did not land
   and may still hold a lockout — the node rebuilds its lockouts from the vote
   account's on-chain state.
4. The node uses `--private-rpc` bound to `127.0.0.1`; RPC is never exposed.
5. **No core dumps.** The validator's memory holds its identity key, so a crash
   must not write that memory to disk. `solana.service` sets `LimitCORE=0`
   (soft and hard) and `CoredumpFilter=elf-headers`: with a pipe `core_pattern`
   such as apport's, the kernel hands the core to the helper whatever the limit,
   and the filter keeps the heap and stack out of it. `deeploy.sh verify` checks
   both on the running process. This holds in both modes: a core would be one
   more copy of the key even where a file exists.
6. **Run a swap over one ssh connection.** Phase 1 rate-limits SSH with
   `ufw limit`, which refuses an address that has opened 6 or more connections
   in the last 30 seconds (ufw(8)). A swap run as a chain of `ssh` and `scp`
   calls can hit that halfway: the printed `offbox` steps alone make three, before
   any check of your own. Open one multiplexed connection first and run every step
   over it:
   `X="ssh -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm-%C -o ControlPersist=600 -o ServerAliveInterval=5 <box>"`,
   then `$X true` as a command of its own — inside `$( )` it hangs, because the
   master keeps that output open — then
   `ssh -o ControlPath=$HOME/.ssh/cm-%C -O check <box>`, and only then the steps,
   each as `$X '…'`.

If you don't want a node to come up and start voting on a fresh identity, **do not
run the final start phase on a key that is already staked elsewhere.**

There is **no warranty.** You are responsible for your keys, your stake, and your
slots. Read the source.

---

