#!/usr/bin/env bash
# Self-contained tests for lib/region.sh — no network. `ping` is mocked with
# canned Linux ping output so the loss/avg/jitter parsing and sorting are
# verified deterministically (this parsing must match the operator's table).
#
# Mock functions shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state"
export DEEPLOY_BACKUP_DIR="$WORK/backups"
export DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1
export DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/constants.sh
source "$ROOT/lib/constants.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/region.sh
source "$ROOT/lib/region.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init

# A ping mock that branches on the last arg (the host) so scoring is meaningful.
# frankfurt fastest, amsterdam next, london next, everything else times out.
ping() {
    local host=${!#}
    case "$host" in
        *frankfurt*) printf '%s\n' "5 packets transmitted, 5 received, 0% packet loss, time 4005ms" \
                                   "rtt min/avg/max/mdev = 7.111/8.000/9.222/0.300 ms"; return 0 ;;
        *amsterdam*) printf '%s\n' "5 packets transmitted, 5 received, 0% packet loss, time 4005ms" \
                                   "rtt min/avg/max/mdev = 11.000/12.500/14.000/0.654 ms"; return 0 ;;
        *london*)    printf '%s\n' "5 packets transmitted, 5 received, 0% packet loss, time 4005ms" \
                                   "rtt min/avg/max/mdev = 18.000/20.000/22.000/0.900 ms"; return 0 ;;
        *)           printf '%s\n' "5 packets transmitted, 0 received, 100% packet loss, time 4010ms"; return 1 ;;
    esac
}

echo "== region_ping parsing =="
ping() { printf '%s\n' "5 packets transmitted, 5 received, 0% packet loss, time 4005ms" \
                       "rtt min/avg/max/mdev = 10.123/12.500/15.789/0.654 ms"; }
check "0% loss, avg, mdev" "$(region_ping h)" "0%|12.500|0.654"
ping() { printf '%s\n' "5 packets transmitted, 3 received, 40% packet loss, time 4010ms" \
                       "rtt min/avg/max/mdev = 10.0/11.500/13.0/0.5 ms"; }
check "partial loss parsed" "$(region_ping h)" "40%|11.500|0.5"
ping() { printf '%s\n' "5 packets transmitted, 0 received, 100% packet loss, time 4010ms"; return 1; }
check "timeout -> sentinel" "$(region_ping h)" "100%|999999|0"

# Restore the branching mock for scoring tests.
ping() {
    local host=${!#}
    case "$host" in
        *frankfurt*) printf '%s\n' "0% packet loss" "rtt min/avg/max/mdev = 7.111/8.000/9.222/0.300 ms"; return 0 ;;
        *amsterdam*) printf '%s\n' "0% packet loss" "rtt min/avg/max/mdev = 11.0/12.500/14.0/0.654 ms"; return 0 ;;
        *london*)    printf '%s\n' "0% packet loss" "rtt min/avg/max/mdev = 18.0/20.000/22.0/0.900 ms"; return 0 ;;
        *)           printf '%s\n' "100% packet loss"; return 1 ;;
    esac
}

echo "== BAM scoring + best =="
BAM_BEST=$(_region_best "$(region_score_bam)")
IFS='|' read -r br _ ba _ bh _ <<<"$BAM_BEST"
check "best BAM region" "$br" "frankfurt"
check "best BAM avg"    "$ba" "8.000"
check "best BAM host"   "$bh" "frankfurt.mainnet.bam.jito.wtf"
check "BAM first row sorts lowest avg" "$(region_score_bam | head -1 | cut -d'|' -f1)" "frankfurt"

echo "== block-engine scoring + shred =="
BE_BEST=$(_region_best "$(region_score_block_engine)")
IFS='|' read -r er _ _ _ eh esh <<<"$BE_BEST"
check "best BE region" "$er" "frankfurt"
check "best BE host"   "$eh" "frankfurt.mainnet.block-engine.jito.wtf"
check "best BE shred"  "$esh" "64.130.50.14:1002"

echo "== region_recommend persists suggestions =="
region_recommend >/dev/null 2>&1
check "suggested_bam_url"          "$(state_get suggested_bam_url)"          "http://frankfurt.mainnet.bam.jito.wtf"
check "suggested_block_engine_url" "$(state_get suggested_block_engine_url)" "https://frankfurt.mainnet.block-engine.jito.wtf"
check "suggested_shred_receiver"   "$(state_get suggested_shred_receiver)"   "64.130.50.14:1002"

echo "== all-timeout: no recommendation, no crash =="
state_clear suggested_bam_url; state_clear suggested_block_engine_url; state_clear suggested_shred_receiver
ping() { printf '%s\n' "100% packet loss"; return 1; }
check "best is empty on all-timeout" "$(_region_best "$(region_score_bam)")" ""
region_recommend >/dev/null 2>&1
check_false "no suggestion persisted on all-timeout" "state_has suggested_bam_url"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
