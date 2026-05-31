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

# Public RPC used only for preflight reachability/genesis probing (never for
# the validator, which is --private-rpc on 127.0.0.1).
DEFAULT_PUBLIC_RPC="https://api.mainnet-beta.solana.com"

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

# Public community metrics endpoints (NOT secrets). BAM is the default to pair
# with BAM-default MEV; the mainnet-beta one is the switchable alternative.
SOLANA_METRICS_BAM="host=http://bam-public-metrics.jito.wtf:8086,db=mainnet-bam-validators,u=mainnet-bam-validator,p=wambamdamn"
SOLANA_METRICS_MAINNET_BETA="host=https://metrics.solana.com:8086,db=mainnet-beta,u=mainnet-beta_write,p=password"
