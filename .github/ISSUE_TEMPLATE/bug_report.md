---
name: Bug report
about: Something DeePloy did that it should not have, or did not do that it should
title: ''
labels: bug
assignees: ''
---

<!-- NOT HERE IF IT IS EXPLOITABLE. Key exfiltration, a destructive step that
runs without the confirmation the code promises, privilege escalation: report
those privately at
https://github.com/zimone91/deeploy/security/advisories/new — see SECURITY.md.
A public issue is a disclosure. -->

## Before you paste anything

DeePloy runs on a box that holds real stake, and its output carries identifiers
from that box. **Redact first**: validator and DoubleZero pubkeys, IP addresses,
hostnames, and interface or facility names.

A bug report does not need them. If a value matters, describe what kind of value
it was and what was wrong with it — "a 44-character base58 pubkey, one character
short" is as useful as the pubkey, and only one of the two can be taken back
afterwards. Removing identifiers that had been published by accident cost this
project a week of its history; that is why the request is here.

## What happened

## What you expected instead

## How to reproduce

```
the exact command, flags included
```

## What did `--dry-run` print?

<!-- Every destructive path has a --dry-run that prints the plan and changes
nothing. Whether the plan was already wrong, or only the execution went wrong,
is usually most of the answer. -->

## Environment

- DeePloy version (`./deeploy.sh --version`):
- Ubuntu version:
- Obtained via: <!-- one-command install / release tarball / git clone -->
