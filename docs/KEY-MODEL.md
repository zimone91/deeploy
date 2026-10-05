## ⚠️ Read this first — the staked-key model

DeePloy never **generates, copies, moves, or transmits** your real staked
validator key, and never places it on the box for you. The node syncs on a
throwaway identity and you swap the staked key in manually (step 2). The tool
does **read** the keypair file in two narrow, local, read-only ways — to derive
its **public** key (the check that it is not the sync identity)
and to produce a single DoubleZero passport signature during `dz-connect` — but
the private key is never written, copied, or sent off the box. Understand the
flow before you run it; this is what separates "fine on testnet" from "I know
what I'm doing on mainnet":

1. DeePloy brings the node up on a **throwaway "fake" identity** and lets it sync.
2. The **real staked key is moved in manually by you**, at the end, with the
   printed `set-identity` commands. DeePloy will not generate, copy, move, or
   transmit it (it reads the file only to derive the public key, and in
   `dz-connect` to sign one passport message).
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
   both on the running process.

If you don't want a node to come up and start voting on a fresh identity, **do not
run the final start phase on a key that is already staked elsewhere.**

There is **no warranty.** You are responsible for your keys, your stake, and your
slots. Read the source.

---

