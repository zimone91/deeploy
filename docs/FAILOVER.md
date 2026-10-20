## Failover

The failover suite is a **separate tool**, intentionally not bundled. DeePloy's
exported `deeploy.conf` is reusable by it; install it later via its own one-line
installer.

Whatever runs a swap, that tool or your own chain of commands, run it over one
multiplexed ssh connection: the box rate-limits SSH (item 6 of
[KEY-MODEL.md](KEY-MODEL.md)).
