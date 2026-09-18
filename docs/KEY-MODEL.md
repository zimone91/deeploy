## ⚠️ Read this first — the staked-key model

DeePloy never **generates, copies, moves, or transmits** your real staked
validator key, and never places it on the box for you. The node syncs on a
throwaway identity and you swap the staked key in manually (step 2). The tool
does **read** the keypair file in two narrow, local, read-only ways — to derive
its **public** key (the identity≠vote check and the upgrade staked-restart guard)
and to produce a single DoubleZero passport signature during `dz-connect` — but
the private key is never written, copied, or sent off the box. Understand the
flow before you run it; this is what separates "fine on testnet" from "I know
what I'm doing on mainnet":

1. DeePloy brings the node up on a **throwaway "fake" identity** and lets it sync.
2. The **real staked key is moved in manually by you**, at the end, with the
   printed `set-identity` commands. DeePloy will not generate, copy, move, or
   transmit it (it reads the file only to derive the public key, and in
   `dz-connect` to sign one passport message).
3. The **tower is *not* transferred.** A fresh node started on an identity with no
   local tower **rebuilds its vote floor from the cluster** — the safe path for a
   first bring-up. (Moving a tower is only for a live-to-live failover swap, which
   is a *separate* tool, out of scope here.)
4. The node uses `--private-rpc` bound to `127.0.0.1`; RPC is never exposed.

If you don't want a node to come up and start voting on a fresh identity, **do not
run the final start phase on a key that is already staked elsewhere.**

There is **no warranty.** You are responsible for your keys, your stake, and your
slots. Read the source.

---

