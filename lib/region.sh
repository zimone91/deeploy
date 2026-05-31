#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/region.sh
# Closest-region recommendation by ICMP latency scoring of Jito's mainnet BAM
# and block-engine hosts. Tables and parsing are lifted from the operator's BAM
# notes; hosts + shred-receiver IPs are PUBLIC Jito infrastructure
# (bam.dev/validators, docs.jito.wtf/lowlatencytxnsend) — not secrets.
#
# Requires: common.sh (and constants.sh for DZ_MULTICAST_SHRED) already sourced.
# Used by preflight (recommendation) and later by config (defaults).
# ============================================================================

[[ -n "${_DEEPLOY_REGION_SOURCED:-}" ]] && return 0
_DEEPLOY_REGION_SOURCED=1

# BAM hosts — "region host"  (mainnet only; testnet omitted by design).
REGION_BAM_HOSTS=(
    "amsterdam  amsterdam.mainnet.bam.jito.wtf"
    "frankfurt  frankfurt.mainnet.bam.jito.wtf"
    "london     london.mainnet.bam.jito.wtf"
    "dublin     dublin.mainnet.bam.jito.wtf"
    "siauliai   siauliai.mainnet.bam.jito.wtf"
    "lax        lax.mainnet.bam.jito.wtf"
    "ny         ny.mainnet.bam.jito.wtf"
    "pittsburgh pittsburgh.mainnet.bam.jito.wtf"
    "slc        slc.mainnet.bam.jito.wtf"
    "dallas     dallas.mainnet.bam.jito.wtf"
    "tokyo      tokyo.mainnet.bam.jito.wtf"
    "singapore  singapore.mainnet.bam.jito.wtf"
)

# Block-engine hosts — "region host shred_receiver"  (shred IPs from docs.jito.wtf).
REGION_BLOCK_ENGINE_HOSTS=(
    "amsterdam amsterdam.mainnet.block-engine.jito.wtf 74.118.140.240:1002"
    "dublin    dublin.mainnet.block-engine.jito.wtf    64.130.61.8:1002"
    "frankfurt frankfurt.mainnet.block-engine.jito.wtf 64.130.50.14:1002"
    "london    london.mainnet.block-engine.jito.wtf    142.91.127.175:1002"
    "ny        ny.mainnet.block-engine.jito.wtf        141.98.216.96:1002"
    "slc       slc.mainnet.block-engine.jito.wtf       64.130.53.8:1002"
    "singapore singapore.mainnet.block-engine.jito.wtf 202.8.11.224:1002"
    "tokyo     tokyo.mainnet.block-engine.jito.wtf     202.8.9.160:1002"
)

REGION_PING_COUNT="${REGION_PING_COUNT:-5}"
REGION_PING_TIMEOUT="${REGION_PING_TIMEOUT:-2}"
REGION_TIMEOUT_SENTINEL=999999          # avg value standing in for unreachable

# region_ping <host> -> "loss|avg|jitter"
# Faithful to the BAM-notes pipeline: parse "N% packet loss", then rebuild the
# rtt line on "/" and cut avg (field 2) and mdev/jitter (field 4). The
# /rtt|round-trip/ match covers both Linux (rtt ...) and BSD (round-trip ...).
region_ping() {
    local host=$1 out loss rtt_line avg jitter
    out=$(ping -n -q -c "$REGION_PING_COUNT" -W "$REGION_PING_TIMEOUT" "$host" 2>&1) || true
    loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+% packet loss' | cut -d' ' -f1)
    rtt_line=$(printf '%s\n' "$out" | awk -F'/' '/rtt|round-trip/{print $4"/"$5"/"$6"/"$7}')
    avg=$(printf '%s' "$rtt_line" | cut -d'/' -f2)
    jitter=$(printf '%s' "$rtt_line" | cut -d'/' -f4 | cut -d' ' -f1)
    [ -z "$loss" ]   && loss="100%"
    [ -z "$avg" ]    && avg="$REGION_TIMEOUT_SENTINEL"
    [ -z "$jitter" ] && jitter="0"
    printf '%s|%s|%s' "$loss" "$avg" "$jitter"
}

# _region_probe_one <region> <host> [shred] -> "region|loss|avg|jitter|host|shred"
_region_probe_one() {
    local region=$1 host=$2 shred=${3:-} triplet
    triplet=$(region_ping "$host")               # loss|avg|jitter
    printf '%s|%s|%s|%s\n' "$region" "$triplet" "$host" "$shred"
}

# Score a table; echo rows sorted by avg ascending (best first).
region_score_bam() {
    local entry region host out=""
    for entry in "${REGION_BAM_HOSTS[@]}"; do
        read -r region host <<<"$entry"
        out+="$(_region_probe_one "$region" "$host")"$'\n'
    done
    printf '%s' "$out" | sort -t'|' -k3,3n
}
region_score_block_engine() {
    local entry region host shred out=""
    for entry in "${REGION_BLOCK_ENGINE_HOSTS[@]}"; do
        read -r region host shred <<<"$entry"
        out+="$(_region_probe_one "$region" "$host" "$shred")"$'\n'
    done
    printf '%s' "$out" | sort -t'|' -k3,3n
}

# First reachable row (avg != sentinel), or empty if all unreachable.
_region_best() {
    printf '%s\n' "$1" | awk -F'|' -v sent="$REGION_TIMEOUT_SENTINEL" '/\|/ && $3!=sent {print; exit}'
}

# Pretty-print a scored table with the BAM-notes color thresholds.
_region_print() {
    local title=$1 data=$2 show_shred=${3:-0}
    echo ""
    info "$title:"
    printf '%s\n' "$data" | awk -F'|' \
        -v g="${C_GREEN:-}" -v y="${C_YELLOW:-}" -v r="${C_RED:-}" -v n="${C_NC:-}" -v ss="$show_shred" -v sent="$REGION_TIMEOUT_SENTINEL" '
        function lat(v){ if(v==sent) return r "TIMEOUT" n; x=v+0; if(x<80) return g v n; if(x<180) return y v n; return r v n }
        function los(v){ if(v=="0%") return g v n; return r v n }
        /\|/ {
            if (ss=="1") printf "    %-11s loss=%-10s avg=%-12s ms  jit=%-6s  %-44s shred=%s\n", $1, los($2), lat($3), $4, $5, $6
            else         printf "    %-11s loss=%-10s avg=%-12s ms  jit=%-6s  %s\n", $1, los($2), lat($3), $4, $5
        }'
}

# region_recommend — score both tables, print them, recommend the closest, and
# persist suggestions for the config phase. Network reads only (no mutation);
# state writes are suppressed under --dry-run like all DeePloy state.
region_recommend() {
    if ! have ping; then
        warn "ping unavailable — skipping region recommendation (choose a region from bam.dev/validators)"
        return 0
    fi
    info "Region scan: pinging ${#REGION_BAM_HOSTS[@]} BAM + ${#REGION_BLOCK_ENGINE_HOSTS[@]} block-engine hosts via ICMP (${REGION_PING_COUNT}x)"
    info "  endpoints: *.mainnet.bam.jito.wtf, *.mainnet.block-engine.jito.wtf"

    local bam be best_bam best_be
    bam=$(region_score_bam)
    _region_print "BAM hosts (by latency)" "$bam" 0
    be=$(region_score_block_engine)
    _region_print "Block-engine + shred receivers (by latency)" "$be" 1

    best_bam=$(_region_best "$bam")
    best_be=$(_region_best "$be")
    if [[ -z "$best_bam" || -z "$best_be" ]]; then
        warn "Could not measure latency (ICMP filtered?) — pick a region manually from bam.dev/validators"
        return 0
    fi

    local bam_region bam_host be_region be_host be_shred
    IFS='|' read -r bam_region _ _ _ bam_host _      <<<"$best_bam"
    IFS='|' read -r be_region  _ _ _ be_host be_shred <<<"$best_be"

    state_set suggested_bam_url          "http://${bam_host}"
    state_set suggested_block_engine_url "https://${be_host}"
    state_set suggested_shred_receiver   "${be_shred}"

    echo ""
    ok "Recommended (closest by latency):"
    info "  BAM URL:          http://${bam_host}   (${bam_region})"
    info "  Block-engine URL: https://${be_host}   (${be_region})"
    info "  Shred receiver:   ${be_shred}"
    info "  With DZ multicast, ${DZ_MULTICAST_SHRED:-233.84.178.1:7733} is appended as a 2nd shred address."
    info "  These are defaults for the config phase — override per host if you prefer."
}
