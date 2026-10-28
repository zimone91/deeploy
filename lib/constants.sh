#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/constants.sh
# Solana mainnet-beta protocol constants. Single source of truth so the same
# values flow into preflight checks and the generated validator.sh (no drift).
# These are PUBLIC network constants, not secrets.
# ============================================================================

# These constants are consumed by sourcing modules (preflight, validatorcfg),
# which the linter can't see cross-file — so silence "unused" file-wide:
# shellcheck disable=SC2034
[[ -n "${_DEEPLOY_CONSTANTS_SOURCED:-}" ]] && return 0
_DEEPLOY_CONSTANTS_SOURCED=1

# mainnet-beta genesis hash — the cluster identity guard.
MAINNET_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"

# Public RPC used for preflight reachability/genesis probing, for the
# cluster's slot in the catchup status and for verify's read of the vote
# account (never for the validator, which is --private-rpc on 127.0.0.1).
DEFAULT_PUBLIC_RPC="https://api.mainnet-beta.solana.com"

# Alpenglow's validator admission ticket (VAT): 0.8 SOL per epoch (at 200 ms
# slots), burned from the vote account (runtime/src/bank.rs,
# maybe_burn_vat_from_staked_accounts, jito-solana v4.3.0-jito.1). Once Alpenglow
# is active the account must hold its rent-exempt minimum plus this
# (minimum_vote_account_balance_for_vat); before that, the rent alone. Alpenglow is
# active on mainnet-beta since epoch 1064 (2026-10-21) and DeePloy runs on
# mainnet-beta only (MAINNET_GENESIS_HASH), so verify always asks for the sum. verify
# reads the rent from the RPC, never from a constant.
VAT_LAMPORTS_PER_EPOCH=800000000

# A node at most this many slots behind the cluster counts as caught up.
# 'solana catchup' (jito c21f9074), from its second poll, needs node_slot >
# min(previous_rpc_slot, rpc_slot) (cli/src/cluster_query.rs 830), the
# previous cluster slot read one 2 s sleep earlier (:658, :901), so its window
# is the slots the cluster makes in 2 s. At the 400 ms target (solana-clock
# 3.2.0 src/lib.rs 77-79) that is 5, a lag of up to 4: this value. At the
# 268.8 ms per slot measured on mainnet on 2026-10-05 it is about 7, a lag of
# up to about 6, so 4 is the stricter. In 26 "has caught up" lines catchup
# printed for a mainnet node on 2026-10-05 and -06, that node was at most 3
# slots behind. Used by the catchup status (common.sh).
CAUGHT_UP_MAX_BEHIND=4

# The five mainnet entrypoints from the install guide (host:port). Used as
# --entrypoint args in validator.sh and pinged for latency in preflight.
MAINNET_ENTRYPOINTS=(
    entrypoint.mainnet-beta.solana.com:8001
    entrypoint2.mainnet-beta.solana.com:8001
    entrypoint3.mainnet-beta.solana.com:8001
    entrypoint4.mainnet-beta.solana.com:8001
    entrypoint5.mainnet-beta.solana.com:8001
)

# Agave AF_XDP support is TWO separate decisions (driver-support matrix):
#   (1) does XDP retransmit work at all?  (2) does ZERO-COPY work?
# Scope now: the NICs validated in production (bnxt_en, mlx5_core). Others -> retransmit offered disabled.
#   mlx5_core -> retransmit + zero-copy   (needs mlx5-irq-affinity.service)
#   bnxt_en   -> retransmit, NO zero-copy (needs nic-tuning.service + ZC preflight)
RETRANSMIT_XDP_DRIVERS=(mlx5_core bnxt_en)   # XDP retransmit supported
RETRANSMIT_ZC_DRIVERS=(mlx5_core)            # zero-copy flag supported (bnxt is non-ZC)

# DoubleZero multicast shred address, appended as a second --shred-receiver-address
# when DZ multicast (edge-solana-shreds) is enabled.
DZ_MULTICAST_SHRED="233.84.178.1:7733"

# Default for MAX_LOCAL_SNAPSHOT_AGE, validator.sh's --maximum-local-snapshot-age:
# two incremental snapshot intervals (5120 slots each). Too small, and a restart
# refuses its own snapshot: on 2026-10-13, at 4000, the cluster's next
# incremental was already 4882 slots ahead, and the download that followed
# looped. Too large, and a start can load a snapshot so far behind that the
# missing slots must come in through repair. On 2026-10-19 a restart 1960 slots
# behind loaded its snapshot and caught up in about 9 minutes. The render
# refuses any age at or below INCREMENTAL_SNAPSHOT_INTERVAL_SLOTS.
DEFAULT_MAX_LOCAL_SNAPSHOT_AGE=10240

# Mainnet known validators (Solana Foundation public set) — --known-validator args.
MAINNET_KNOWN_VALIDATORS=(
    7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2
    GdnSyH3YtwcxFvQrVVJMm1JhTS4QVX7MFsX56uJLUfiZ
    DE1bawNcRJB9rVm3buyMVfr8mBEoyyu73NBovf2oXJsJ
    CakcnaRDHka2gXyfbEd2d3xsvkJkqsLw2akB3zsN1D2S
)

# Jito on-chain addresses (public — jito-foundation.gitbook.io/mev .../on-chain-addresses)
# and the Address Lookup Table program id (for --account-index-include-key).
JITO_TIP_PAYMENT_PROGRAM="T1pyyaTNZsKv2WcRAB8oVnk93mLJw2XzjtVYqCsaHqt"
JITO_TIP_DISTRIBUTION_PROGRAM="4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7"
JITO_MERKLE_ROOT_AUTHORITY="8F4jGUmxF36vQ6yabnsxX6AQVXdKBhs8kGSUuRKSg8Xt"
ALT_PROGRAM_KEY="AddressLookupTab1e1111111111111111111111111"

# Oldest jito-solana tag DeePloy can build and render for. Not a taste call: the
# generated validator.sh carries --no-xdp where XDP is off, and --no-xdp first
# exists in 4.2.0, where XDP became opt-out (the XDP flags landed in 4.1.0). On
# anything older the validator rejects the argv and never starts — after the
# whole build. One constant, three checks (build, upgrade, render) so the floor
# cannot drift between them.
DEEPLOY_MIN_JITO_TAG="v4.2.0-jito"

# Recommended jito-solana tag. The floor above refuses; this only warns, at the
# same three checks, and the run goes on. SFDP requires Agave 4.3.2 or newer from
# epoch 1063 (api.solana.org/api/community/v1/sfdp_required_versions). The note is
# deeploy_tag_recommendation_note (common.sh): the floor's own comparison, against
# this tag. It is SFDP's requirement and says nothing of which tags run Alpenglow:
# votor, the migration code and the vote-history guard are already in the
# v4.2.0-jito tree.
DEEPLOY_RECOMMENDED_JITO_TAG="v4.3.2-jito.0"
DEEPLOY_RECOMMENDED_JITO_WHY="SFDP requires Agave 4.3.2 or newer from epoch 1063"

# The shipped pin: the tag deeploy.conf.example names, and the one a bare Enter
# at the install's tag prompt builds. It may move ahead of the recommendation,
# never below it (test_common).
DEEPLOY_PIN_JITO_TAG="v4.3.2-jito.0"
# The commit it is pinned to. v4.3.2-jito.0 is an annotated tag that peels to it
# (git ls-remote on 2026-10-27; a build reports its first eight digits, src:7037b4f4).
# A tag can be moved after it was pinned and a commit cannot, so a build of the
# pin refuses any other commit (toolchain_check_commit). Bump the two together.
DEEPLOY_PIN_JITO_COMMIT="7037b4f425e655b8f973ee8ebea9a4de1a85b208"

# Public community metrics endpoints (NOT secrets). mainnet-beta is the default:
# it is the endpoint Anza's cluster docs and Jito's BAM guide give (docs/INSTALL.md,
# Metrics). SFDP's metric-reporting check used to read one core metric,
# optimistic_slot.slot, from that database (metrics.solana.com). Under Alpenglow the
# validator no longer sends it (jito-solana v4.3.2-jito: core/src/
# optimistic_confirmation_verifier.rs 80 is the datapoint's only source, and
# core/src/cluster_info_vote_listener.rs 657-660 drops that verifier), and SFDP's API
# lists the exemption metric-reporting-ignored for epochs 1062 and 1063 (read
# 2026-10-22, one validator). The BAM endpoint is an explicit choice,
# METRICS_TARGET=bam (lib/validatorcfg.sh).
SOLANA_METRICS_BAM="host=http://bam-public-metrics.jito.wtf:8086,db=mainnet-bam-validators,u=mainnet-bam-validator,p=wambamdamn"
SOLANA_METRICS_MAINNET_BETA="host=https://metrics.solana.com:8086,db=mainnet-beta,u=mainnet-beta_write,p=password"
