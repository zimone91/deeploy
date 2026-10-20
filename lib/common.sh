#!/usr/bin/env bash
# ============================================================================
# DeePloy — lib/common.sh
# Foundation library: interactive prompts, structured logging, run-state,
# timestamped backups, and idempotent file edits (ensure_line / ensure_block).
#
# This file is sourced, never executed directly. It must be safe to source in
# a test harness (no side effects until common_init is called) and must not
# enable `set -e` itself — the entrypoint (deeploy.sh) owns shell options.
#
# Public output vocabulary (lifted from the failover deploy script):
#   step "Title"   ok "msg"   info "msg"   warn "msg"   fail "msg"   debug "msg"
# Public prompts (REPLY convention preserved from the failover script):
#   ask  ask_choice  ask_path  confirm  require_yes
# Idempotent edits:
#   backup_file  restore_file  ensure_line  ensure_block  ensure_kv
# Run/state:
#   run  is_dry_run  state_set/get/has/clear  mark_phase_done/is_phase_done
# ============================================================================

# Guard against double-sourcing.
[[ -n "${_DEEPLOY_COMMON_SOURCED:-}" ]] && return 0
_DEEPLOY_COMMON_SOURCED=1

# ----------------------------------------------------------------------------
# Defaults (so `source common.sh` alone is inert and test-friendly).
# All of these may be overridden by deeploy.sh's arg parser or by env in tests.
# ----------------------------------------------------------------------------
DEEPLOY_VERSION="${DEEPLOY_VERSION:-0.1.0-rc10}"

# How to invoke DeePloy in printed instructions. There is no `deeploy` in PATH —
# the operator runs the script by path. deeploy.sh sets DEEPLOY_SELF (its own
# absolute path); prefer that, else fall back to the relative invocation. Used in
# all operator-facing "run: <cmd> dz-connect/export/…" text.
DEEPLOY_CMD="${DEEPLOY_CMD:-${DEEPLOY_SELF:-./deeploy.sh}}"

: "${DRY_RUN:=0}"          # 1 = print plan; change nothing outside a temp dir, removed on exit
: "${ASSUME_YES:=0}"       # 1 = auto-confirm normal prompts (never disk wipes)
: "${POST_REBOOT:=0}"      # 1 = unattended resume after reboot (forces non-interactive)
: "${NONINTERACTIVE:=}"    # decided in common_init from tty unless set explicitly
: "${DEEPLOY_DEBUG:=0}"    # 1 = show DEBUG on console

# Set by phase_begin(); read by the exit trap to report where a run died.
CURRENT_PHASE=""
CURRENT_PHASE_NAME=""

# ----------------------------------------------------------------------------
# Colors — enabled only on a real terminal, honoring NO_COLOR / DEEPLOY_COLOR.
# ----------------------------------------------------------------------------
_init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${DEEPLOY_COLOR:-auto}" != "never" ]]; then
        C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
        C_CYAN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
    else
        C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_NC=''
    fi
}
_init_colors

# ----------------------------------------------------------------------------
# Timestamps.
# ----------------------------------------------------------------------------
_ts()      { date -u +%Y-%m-%dT%H:%M:%SZ; }   # for log lines
_ts_run()  { date -u +%Y%m%d-%H%M%S; }        # for run/backup directory names

# ----------------------------------------------------------------------------
# Structured logging.
#   _log <LABEL> <message...>   (internal) — LABEL doubles as the level.
# Everything is appended to $LOG_FILE (when set + writable). Console routing and
# coloring is done by the wrappers (step/ok/info/warn/fail/debug).
# ----------------------------------------------------------------------------
_log() {
    local label=$1; shift
    [[ -n "${LOG_FILE:-}" ]] || return 0
    printf '%s [%-5s] %s\n' "$(_ts)" "$label" "$*" >>"$LOG_FILE" 2>/dev/null || true
    return 0
}

step() {
    printf '\n%s━━━ %s ━━━%s\n' "$C_CYAN" "$*" "$C_NC"
    _log STEP "=== $* ==="
}
ok()   { printf '%s  [OK]%s %s\n'   "$C_GREEN"  "$C_NC" "$*";        _log OK   "$*"; }
info() { printf '  %s\n' "$*";                                       _log INFO "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$C_YELLOW" "$C_NC" "$*" >&2;    _log WARN "$*"; }
debug() {
    [[ "$DEEPLOY_DEBUG" == "1" ]] && printf '%s  [..] %s%s\n' "$C_DIM" "$*" "$C_NC" >&2
    _log DEBUG "$*"
}
# fail prints, logs, and exits. The EXIT trap (if installed) handles cleanup.
fail() {
    printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_NC" "$*" >&2
    _log FAIL "$*"
    exit 1
}

# ----------------------------------------------------------------------------
# Small utilities.
# ----------------------------------------------------------------------------
is_dry_run()    { [[ "$DRY_RUN" == "1" ]]; }
is_interactive(){ [[ "${NONINTERACTIVE}" != "1" ]]; }
have()          { command -v "$1" >/dev/null 2>&1; }
require_root()  { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Must run as root"; }

require_cmds() {
    local missing=() c
    for c in "$@"; do have "$c" || missing+=("$c"); done
    [[ ${#missing[@]} -eq 0 ]] || fail "Missing required commands: ${missing[*]}"
}

_mktemp() { mktemp "${TMPDIR:-/tmp}/deeploy.XXXXXX"; }

# --- checkout safety (N8) ----------------------------------------------------
# The post-reboot resume unit executes THIS checkout as root at boot, so an
# unsafe checkout is a root-persistence vector: any local user who can write the
# path could swap the script between install and the reboot. Two consumers share
# this ONE predicate — preflight (fails in the first seconds) and the install-
# time gate right before the unit is written (fails closed no matter how the run
# got there). Deliberately not duplicated: a read/write pair that drifts apart is
# exactly the N5/N13 bug class.
# Split out as mockable helpers; GNU stat first, then BSD.
deeploy_path_uid()  { stat -c %u  "$1" 2>/dev/null || stat -f %u  "$1" 2>/dev/null || true; }
deeploy_path_mode() { stat -c %a  "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }

# Prints WHY the given paths are unsafe and returns 1; prints nothing and
# returns 0 when every path is root-owned and not group/world-writable. An
# unreadable/unparsable mode counts as unsafe (fail-closed).
deeploy_checkout_unsafe_reason() {                # <path>...
    local f uid mode
    for f in "$@"; do
        uid="$(deeploy_path_uid "$f")"
        mode="$(deeploy_path_mode "$f")"
        if [[ "$uid" != "0" ]]; then
            printf '%s is not root-owned (uid %s)' "$f" "${uid:-?}"
            return 1
        fi
        if [[ ! "$mode" =~ ^[0-7]+$ ]] || (( (8#$mode & 8#022) != 0 )); then
            printf '%s is group/world-writable (mode %s)' "$f" "${mode:-?}"
            return 1
        fi
    done
    return 0
}

# Whether a path can actually be executed. Deliberately NOT folded into
# deeploy_checkout_unsafe_reason: that one answers a security question — who is
# allowed to write this — and this one answers whether the file can run at all.
# Folding them would make its ok line ("root-owned and not group/world-writable")
# claim something it never measured.
#
# The reason this exists at runtime and not only as a gate: the resume unit's
# ExecStart is this script's own path, and `systemctl enable` does not look at
# the bit. A 644 entry point enables cleanly and fails at boot with
# status=203/EXEC — after the reboot, on a box whose disks were erased three
# phases earlier. v0.1.0-rc6 shipped that, because git archive preserves index
# modes and the bit had never been set. A gate in this repository cannot see a
# checkout someone chmod'ed by hand, or unpacked with a umask of their own.
deeploy_not_executable_reason() {                 # <path> -> 0 executable, else 1 + reason
    local p="$1" m
    [[ -e "$p" ]] || { printf '%s does not exist' "$p"; return 1; }
    m=$(deeploy_path_mode "$p")
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || { printf 'the mode of %s could not be read' "$p"; return 1; }
    (( (8#$m & 0111) != 0 )) || { printf '%s is mode %s and is not executable' "$p" "$m"; return 1; }
    return 0
}

# The root-execution surface: every path whose CONTENTS deeploy.sh runs as root,
# which is this script plus the modules it sources. Globbed, never listed — a
# list here would be a second copy of the loader's, and the copy that goes stale
# is always the one nobody remembered to update.
#
# deeploy.conf is deliberately NOT in this set. It is parsed as data and never
# sourced, eval'd or executed ("The conf is DATA, never code" — config.sh), so a
# writable conf cannot put code into a root process. Add to this set only what is
# sourced or executed, never what is merely read; the next person will otherwise
# widen it by guessing.
#
# Why it matters that this is wider than the two paths it used to check: the unit
# written at the reboot boundary runs deeploy.sh as root, and deeploy.sh sources
# every module before it does anything. A lib/*.sh a local user can write is the
# same root-persistence vector the gate exists to close, one directory down.
deeploy_root_surface_unsafe_reason() {            # <checkout-dir> <self> <lib-dir>
    local dir="$1" self="$2" lib="$3" m
    deeploy_checkout_unsafe_reason "$dir" "$self" || return 1
    for m in "$lib"/*.sh; do
        [[ -e "$m" ]] || continue
        deeploy_checkout_unsafe_reason "$m" || return 1
    done
    return 0
}

# --- client tag parsing + version floor --------------------------------------
# jito-solana version tags take the form
# vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N] (v4.3.0-jito.0,
# v4.2.0-beta.2-jito.1); every jito-solana release at or above the floor is
# tagged this way (measured 2026-10-04). The jito-solana repo also carries bare
# Agave tags (v4.3.0 among them), which do not have the form. Three consumers
# need the same answer — the build (toolchain), the upgrade path, and the
# RENDER (validatorcfg emits flags whose existence depends on the version) — so
# the parser and the floor comparison live here, once. Same convention as
# deeploy_checkout_unsafe_reason: the predicate reports WHAT is wrong, each
# caller adds the remedy that fits its context.

# Prints "MAJOR MINOR PATCH"; returns 1 (silent) on anything that is not a
# version tag. Prerelease shapes parse on their numeric head, so
# v4.2.0-beta.2-jito.1 -> "4 2 0"; 'latest', 'v4.2' and '' do not parse at all.
# Only the numeric head is read, which is all the floor needs — so a bare Agave
# tag (v4.3.0) parses too. Whether a tag is a jito tag at all is the question
# deeploy_tag_agave_base answers.
deeploy_tag_version() {                           # <tag>
    [[ "${1:-}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Prints the Agave base a jito-solana tag names — the name of the Anza release
# phase 4 installs the CLI from: v4.3.0-jito.0 -> v4.3.0,
# v4.3.0-rc.1-jito.1 -> v4.3.0-rc.1. Prints nothing and returns 1 for anything
# else, a bare Agave tag (v4.3.0) included. The prerelease is limited to
# -alpha.N, -beta.N or -rc.N on purpose: a free-form one would accept
# v4.3.0-jito-jito and v4.3.0-bam-jito, whose bases have no Anza release (404)
# — the same failure as the hand-stripped ${TAG%-jito} this replaces, which
# leaves v4.3.0-jito.0 whole: release.anza.xyz has no release by that name.
deeploy_tag_agave_base() {                        # <tag>
    [[ "${1:-}" =~ ^(v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?)-jito(\.[0-9]+)?$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# Prints WHY <tag> cannot be used and returns 1; prints nothing and returns 0
# when it parses and is >= the floor (default: DEEPLOY_MIN_JITO_TAG).
deeploy_tag_floor_problem() {                     # <tag> [<floor-tag>]
    local tag=${1:-} floor=${2:-${DEEPLOY_MIN_JITO_TAG:-}} tv fv
    local tmaj tmin tpat fmaj fmin fpat tnum fnum
    if ! tv="$(deeploy_tag_version "$tag")"; then
        printf "'%s' is not a jito-solana version tag (expected vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]-jito[.N])" "$tag"
        return 1
    fi
    if ! fv="$(deeploy_tag_version "$floor")"; then
        printf "internal: version floor '%s' is not a version tag" "$floor"
        return 1
    fi
    read -r tmaj tmin tpat <<<"$tv"
    read -r fmaj fmin fpat <<<"$fv"
    # 10# so a zero-padded component (v4.08.0) is decimal, not octal. Components
    # are assumed < 1000, which every Solana client release has honored.
    tnum=$(( 10#$tmaj * 1000000 + 10#$tmin * 1000 + 10#$tpat ))
    fnum=$(( 10#$fmaj * 1000000 + 10#$fmin * 1000 + 10#$fpat ))
    (( tnum >= fnum )) && return 0
    printf "%s is older than the minimum supported %s" "$tag" "$floor"
    return 1
}

# Prints one line when <tag> is a version below DEEPLOY_RECOMMENDED_JITO_TAG,
# nothing otherwise: the floor's comparison above, against the recommendation.
# Always returns 0, because the three callers read it inside $( ), where a
# non-zero status wakes the ERR trap. Garbage prints nothing: refusing it is the
# floor's job, and every caller runs that check first.
deeploy_tag_recommendation_note() {               # <tag>
    deeploy_tag_floor_problem "${1:-}" "${DEEPLOY_RECOMMENDED_JITO_TAG:-}" >/dev/null && return 0
    deeploy_tag_version "${1:-}" >/dev/null || return 0
    printf '%s is below the recommended %s: %s' "$1" "$DEEPLOY_RECOMMENDED_JITO_TAG" "$DEEPLOY_RECOMMENDED_JITO_WHY"
    return 0
}

# ensure_cargo_env — make the rustup-installed cargo/rustc resolvable for THIS
# process. rustup installs to $HOME/.cargo/bin and writes $HOME/.cargo/env, but a
# fresh install only affects PATH if that env is sourced — and it must reach
# EVERY later step that shells out to cargo (the toolchain build AND nic.sh's XDP
# self-check), not only the function that ran the install. Two failure modes this
# closes: (1) under sudo's secure_path the inherited PATH lacks ~/.cargo/bin even
# though cargo exists; (2) on --resume, Phase 4 (which sources the env) is skipped
# as already-done, so the process that reaches nic.sh never had it sourced.
# Idempotent (PATH guarded against double-prepend) and a safe no-op when cargo
# isn't installed — the caller's own `cargo: command not found` handling stands.
# deeploy_solana_bin — the active-release bin dir, resolved WITHOUT depending on
# $HOME. Under the systemd resume service $HOME is empty, so "$HOME/.local/..."
# collapsed to "/.local/..." and Phase 8's catchup loop ran the wrong path. Order:
#   1) an explicitly-set SOLANA_BIN (tests / --config) wins;
#   2) the path recorded to state by toolchain_install_release (authoritative);
#   3) ${SOLANA_INSTALL_HOME:-/root}/.local/... — DeePloy runs as root, so /root
#      is the correct base; never the empty-HOME "/.local/...".
# Modules use this for their SOLANA_BIN default instead of "$HOME/.local/...".
deeploy_solana_bin() {
    if [[ -n "${SOLANA_BIN:-}" ]]; then printf '%s' "$SOLANA_BIN"; return 0; fi
    local s; s="$(state_get solana_bin "")"
    if [[ -n "$s" ]]; then printf '%s' "$s"; return 0; fi
    printf '%s' "${SOLANA_INSTALL_HOME:-/root}/.local/share/solana/install/active_release/bin"
}

# --- identities (read-only; shared by upgrade.sh and verify.sh) ---------------
# The staked identity is applied at runtime with set-identity, so argv
# (/proc/<pid>/cmdline) always shows the sync identity and a keypair file proves
# nothing about the running process. Only the node itself can tell: getIdentity
# on the local RPC. The value probes print nothing on failure and always return
# 0: a non-zero status inside $( ) wakes the ERR trap and prints a stray [FAIL]
# line.
deeploy_live_identity() {       # stdout: the base58 identity, or nothing (no answer / unparsable)
    local port out
    port=$(state_get rpc_port 8899)
    out=$(curl -sS -m 5 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getIdentity"}' "http://127.0.0.1:${port}" 2>/dev/null || true)
    printf '%s\n' "$out" | sed -nE 's/.*"identity"[[:space:]]*:[[:space:]]*"([1-9A-HJ-NP-Za-km-z]{32,44})".*/\1/p' | head -1
}
deeploy_sync_pubkey() {         # stdout: the sync identity's pubkey, or nothing
    local f; f=$(state_get sync_identity "")
    if [[ -n "$f" && -f "$f" ]]; then "$SOLANA_BIN/solana-keygen" pubkey "$f" 2>/dev/null || true; fi
}

# --- catchup status (read-only; shared by start.sh and verify.sh) -------------
# How far the node is behind, read without waiting for it to catch up: two
# getSlot calls at "confirmed" (the CLI's default commitment), each capped at
# 5 s. The cluster's slot comes first, from the public RPC (DEFAULT_PUBLIC_RPC,
# constants.sh), then the node's own, so the node's is the fresher of the two.
# Up to CAUGHT_UP_MAX_BEHIND slots behind counts as caught up; constants.sh
# says how that compares with 'solana catchup'. Through a pipe that command
# says nothing until the end: while behind it reports only on a spinner,
# which is not drawn when stderr is not a terminal, so its first line is the
# final "has caught up".
_deeploy_rpc_slot() {           # <url>; stdout: the slot, or nothing (no answer / unparsable)
    local out
    out=$(curl -sS -m 5 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"confirmed"}]}' "$1" 2>/dev/null || true)
    printf '%s\n' "$out" | sed -nE 's/.*"result"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p'
}
deeploy_catchup_status() {      # stdout: one line, "caught up (us:N them:M)" or why not
    local node us them
    node="http://127.0.0.1:$(state_get rpc_port 8899)"
    them=$(_deeploy_rpc_slot "$DEFAULT_PUBLIC_RPC")
    us=$(_deeploy_rpc_slot "$node")
    if [[ -z "$us" ]]; then echo "no slot from the node's RPC at $node"
    elif [[ -z "$them" ]]; then echo "no slot from the cluster RPC at $DEFAULT_PUBLIC_RPC (us:$us)"
    elif (( them - us <= CAUGHT_UP_MAX_BEHIND )); then echo "caught up (us:$us them:$them)"
    else echo "$((them - us)) slots behind (us:$us them:$them)"; fi
}

# b58_len <string> — how many bytes <string> decodes to as base58 (the alphabet
# Solana uses), or nothing when a character is outside the alphabet. A pubkey
# is 32 bytes and a signature 64; a 32-44 character regex alone lets 23-33 byte
# values through. Pure bash on base-256 digits; always returns 0.
b58_len() {
    local s=$1 alpha=123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
    local -a b=()
    local i j n=0 z=0 carry rest
    [[ -n "$s" ]] || return 0
    while [[ "${s:z:1}" == 1 ]]; do z=$((z + 1)); done     # each leading '1' is a zero byte
    for ((i = 0; i < ${#s}; i++)); do
        rest=${alpha%%"${s:i:1}"*}
        (( ${#rest} < 58 )) || return 0                    # not in the alphabet
        carry=${#rest}
        for ((j = 0; j < n; j++)); do
            carry=$(( b[j] * 58 + carry )); b[j]=$(( carry & 255 )); carry=$(( carry >> 8 ))
        done
        while (( carry > 0 )); do b[n]=$(( carry & 255 )); n=$((n + 1)); carry=$(( carry >> 8 )); done
    done
    printf '%s\n' $(( n + z ))
}

ensure_cargo_env() {
    local ch="${CARGO_HOME:-$HOME/.cargo}"
    # shellcheck disable=SC1090,SC1091
    [[ -r "$ch/env" ]] && source "$ch/env"            # rustup's env (may or may not be PATH-idempotent)
    # Ensure ~/.cargo/bin is on PATH EXACTLY once. Rebuild PATH dropping any
    # existing occurrence, then prepend — so repeat calls (and a non-idempotent
    # env file) never stack duplicate entries.
    if [[ -d "$ch/bin" ]]; then
        local newp="" seg IFS=':'
        for seg in $PATH; do [[ "$seg" == "$ch/bin" ]] || newp="${newp:+$newp:}$seg"; done
        export PATH="$ch/bin${newp:+:$newp}"
    fi
    debug "ensure_cargo_env: cargo=$(command -v cargo 2>/dev/null || echo '<not found>')"
    return 0
}

# run — execute a state-changing command, honoring --dry-run.
# Use for simple argv commands; redirections/pipes must guard with is_dry_run.
run() {
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} $*"
        _log DRYRUN "$*"
        return 0
    fi
    debug "+ $*"
    "$@"
}

# _redact_argv <flag> <args...> — echo the args space-joined, with the single
# token following <flag> replaced by ***. Used to LOG a command without leaking
# a secret value (e.g. a signature); never alters what is executed.
_redact_argv() {
    local flag=$1; shift
    local out=()
    while (( $# )); do
        out+=("$1")
        if [[ "$1" == "$flag" ]] && (( $# > 1 )); then
            out+=("***"); shift 2; continue
        fi
        shift
    done
    printf '%s' "${out[*]}"
}

# run_redacted <flag> <cmd...> — like run(), but the DEBUG/dry-run log shows the
# value following <flag> masked as *** (the real argv is executed UNCHANGED).
# Use when an argument is secret, e.g. a passport --signature. (X4)
run_redacted() {
    local redact=$1; shift
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} $(_redact_argv "$redact" "$@")"
        _log DRYRUN "$(_redact_argv "$redact" "$@")"
        return 0
    fi
    debug "+ $(_redact_argv "$redact" "$@")"
    "$@"
}

# apply_sysctl_file <file> — apply a sysctl drop-in TOLERANTLY (belt + suspenders
# for set -e). `sysctl -p <file>` returns non-zero the moment it hits a key whose
# subtree isn't present yet — e.g. fs.xfs.* before the xfs module is loaded, or a
# tcp_congestion_control whose module is absent — and under the installer's
# `set -Eeuo pipefail` that single missing key would abort the whole run. We
# apply key-by-key instead: a rejected key WARNS (naming it) and every other key
# still takes effect; the function always returns 0. Honors --dry-run.
apply_sysctl_file() {
    local file=$1 line="" key value skipped=0
    # Dry-run first: a dry-run's write_file does not write the file, so on a
    # fresh box it is not there, and that is not a fault (DRYRUN-SYSCTL-WARN).
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would apply sysctl keys from $file (tolerant)"; return 0; fi
    [[ -f "$file" ]] || { warn "sysctl file not found: $file"; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                                  # drop comments
        [[ "$line" =~ [^[:space:]] ]] || continue            # skip blank lines
        [[ "$line" == *=* ]] || continue                     # skip non key=value
        key="${line%%=*}";  key="${key//[[:space:]]/}"       # keys never contain spaces
        value="${line#*=}"; value="${value#"${value%%[![:space:]]*}"}"   # ltrim value (keep internal spaces)
        if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            debug "sysctl ${key}=${value}"
        else
            warn "sysctl: '${key}' not accepted (kernel subtree not present yet?) — skipped"
            skipped=$((skipped + 1))
        fi
    done < "$file"
    (( skipped > 0 )) && warn "sysctl: applied ${file} with ${skipped} key(s) skipped"
    return 0
}

# ----------------------------------------------------------------------------
# Interactive prompts — REPLY convention preserved from the failover script.
# In non-interactive mode the default is used; a missing default is fatal so we
# never silently guess or block on a closed stdin (e.g. systemd resume).
# ----------------------------------------------------------------------------

# ask "Prompt" "default"  -> answer in $REPLY
ask() {
    local prompt="$1" default="${2:-}"
    if ! is_interactive; then
        [[ -n "$default" ]] || fail "Non-interactive: no value and no default for: $prompt"
        REPLY="$default"; debug "ask(non-interactive): $prompt -> $REPLY"; return 0
    fi
    if [[ -n "$default" ]]; then
        printf '%s  %s%s [%s]: ' "$C_BOLD" "$prompt" "$C_NC" "$default"
    else
        printf '%s  %s%s: ' "$C_BOLD" "$prompt" "$C_NC"
    fi
    read -r REPLY || REPLY=""
    [[ -z "$REPLY" ]] && REPLY="$default" || true
}

# ask_choice "Prompt" "default" choice1 choice2 ...  -> validated answer in $REPLY
ask_choice() {
    local prompt="$1" default="$2"; shift 2
    local choices=("$@") c choices_str
    choices_str=$(IFS=/; printf '%s' "${choices[*]}")
    if ! is_interactive; then
        REPLY="$default"
        for c in "${choices[@]}"; do [[ "$REPLY" == "$c" ]] && { debug "ask_choice(non-interactive): $prompt -> $REPLY"; return 0; }; done
        fail "Non-interactive: default '$default' not in {$choices_str} for: $prompt"
    fi
    while true; do
        if [[ -n "$default" ]]; then
            printf '%s  %s%s (%s) [%s]: ' "$C_BOLD" "$prompt" "$C_NC" "$choices_str" "$default"
        else
            printf '%s  %s%s (%s): ' "$C_BOLD" "$prompt" "$C_NC" "$choices_str"
        fi
        read -r REPLY || REPLY=""
        [[ -z "$REPLY" ]] && REPLY="$default"
        for c in "${choices[@]}"; do [[ "$REPLY" == "$c" ]] && return 0; done
        warn "Invalid choice: '$REPLY'. Must be one of: $choices_str"
    done
}

# ask_path "Prompt" "default" "required(true/false)"  -> path in $REPLY
# Warns (does not hard-fail) when a non-empty path is missing, so a key that
# will be placed later can still be configured.
ask_path() {
    local prompt="$1" default="${2:-}" required="${3:-false}" yn
    while true; do
        ask "$prompt" "$default"
        if [[ -z "$REPLY" && "$required" == "true" ]]; then
            warn "This field is required"; is_interactive || fail "Non-interactive: required path missing for: $prompt"; continue
        fi
        if [[ -n "$REPLY" && ! -e "$REPLY" ]]; then
            warn "Path not found: $REPLY"
            if is_interactive; then
                printf '  Continue anyway? (y/N): '; read -r yn || yn=""
                if [[ "$yn" == "y" || "$yn" == "Y" ]]; then break; else continue; fi
            fi
        fi
        break
    done
}

# confirm "Prompt" "default(Y/N)"  -> exit status 0 (yes) / 1 (no)
# Honors --yes for ordinary confirmations. Never use for disk wipes.
confirm() {
    local prompt="$1" default="${2:-N}" yn
    if [[ "$ASSUME_YES" == "1" ]]; then debug "confirm(--yes): $prompt"; return 0; fi
    if ! is_interactive; then [[ "$default" =~ ^[Yy]$ ]]; return; fi
    local hint="y/N"; [[ "$default" =~ ^[Yy]$ ]] && hint="Y/n"
    while true; do
        printf '%s  %s%s (%s): ' "$C_BOLD" "$prompt" "$C_NC" "$hint"
        read -r yn || yn=""
        [[ -z "$yn" ]] && yn="$default"
        case "$yn" in [Yy]*) return 0;; [Nn]*) return 1;; *) warn "Please answer y or n";; esac
    done
}

# require_yes "Prompt" — destructive-action gate. Requires the literal word
# "yes". NEVER honors --yes and refuses in non-interactive mode. Returns
# non-zero if the user declines, so callers can abort the destructive step.
require_yes() {
    local prompt="$1" reply
    if ! is_interactive; then
        warn "Non-interactive: refusing destructive action without explicit confirmation: $prompt"
        return 1
    fi
    printf "%s  %s%s\n  Type %s'yes'%s to proceed: " "$C_BOLD" "$prompt" "$C_NC" "$C_BOLD" "$C_NC"
    read -r reply || reply=""
    [[ "$reply" == "yes" ]]
}

# ----------------------------------------------------------------------------
# Run-state: per-phase markers + small key/value store under $STATE_DIR.
# A dry-run never writes $STATE_DIR. Its writes go to a SHADOW store in a temp
# dir and its reads see the shadow first, so a later phase plans from what an
# earlier one decided (XDP cores, DoubleZero, the MEV region, reboot_required)
# instead of from defaults (R10-7e). Without a shadow — a unit test calling
# these under DRY_RUN=1 without common_init — dry-run writes are no-ops.
# ----------------------------------------------------------------------------
_state_file() { printf '%s/state.d/%s' "$STATE_DIR" "$1"; }

# The shadow: set/<key> holds a value written in this dry-run, cleared/<key> is
# a tombstone hiding the real value after a dry-run state_clear. common_init
# makes it and the exit trap removes it: on success, on refusal, and on INT,
# TERM, HUP, PIPE, ALRM and USR1 (measured on bash 5.2 and 3.2). SIGKILL leaves
# it behind in $TMPDIR, and so does SIGQUIT on bash 3.2; bash 5.2 ignores
# SIGQUIT. So a dry-run changes nothing outside a temp dir, removed on exit.
# It still READS: the live box, and the network (the region probe, the 7d tag
# check). Set only by _state_shadow_init — reset here so the environment can
# never name a dir for the exit trap to remove.
_STATE_SHADOW=""
_state_shadow_init() {
    local d=""
    if d=$(mktemp -d "${TMPDIR:-/tmp}/deeploy-dryrun.XXXXXX" 2>/dev/null) && mkdir "$d/set" "$d/cleared" 2>/dev/null; then
        _STATE_SHADOW=$d
        debug "dry-run state shadow: $d"
        return 0
    fi
    if [[ -n "$d" && -d "$d" ]]; then rm -rf -- "$d"; fi
    # A plan that silently read defaults (no XDP, no DoubleZero, no MEV
    # endpoints) would be worse than none.
    fail "dry-run cannot keep its own state: cannot create a temp dir in ${TMPDIR:-/tmp}. Refusing — its plan would read defaults. Set TMPDIR to a writable directory and run again."
}
_state_shadowed() { is_dry_run && [[ -n "${_STATE_SHADOW:-}" ]]; }

state_set() {
    local key=$1 val=$2 f tmp; f=$(_state_file "$key")
    if is_dry_run; then
        # set/ is read before cleared/, so a value written after a clear wins.
        if [[ -n "${_STATE_SHADOW:-}" ]]; then
            printf '%s' "$val" >"$_STATE_SHADOW/set/$key" \
                || { warn "state_set: cannot write the dry-run shadow ${_STATE_SHADOW}"; return 1; }
        fi
        debug "[dry-run] state_set $key=$val"; return 0
    fi
    mkdir -p "$(dirname "$f")" || return 1
    # Atomic (N15): write a temp file IN the state dir (same filesystem) then
    # rename — a mid-write kill (power loss, OOM during the resume service)
    # leaves either the old or the new value, never a truncated file. The
    # chmod matches the plain '>file' creation this replaces (default-umask
    # 644; mktemp files are born 0600), so read semantics are unchanged.
    tmp=$(mktemp "$(dirname "$f")/.${key}.XXXXXX") \
        || { warn "state_set: cannot create a temp file in $(dirname "$f")"; return 1; }
    printf '%s' "$val" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; warn "state_set: rename to ${f} failed"; return 1; }
    debug "state_set $key=$val"
}
state_get() {
    local key=$1 def=${2:-} f
    if _state_shadowed; then
        if [[ -f "$_STATE_SHADOW/set/$key" ]]; then cat "$_STATE_SHADOW/set/$key"; return 0; fi
        if [[ -e "$_STATE_SHADOW/cleared/$key" ]]; then printf '%s' "$def"; return 0; fi
    fi
    f=$(_state_file "$key"); [[ -f "$f" ]] && cat "$f" || printf '%s' "$def"
}
state_has() {
    if _state_shadowed; then
        if [[ -f "$_STATE_SHADOW/set/$1" ]]; then return 0; fi
        if [[ -e "$_STATE_SHADOW/cleared/$1" ]]; then return 1; fi
    fi
    [[ -f "$(_state_file "$1")" ]]
}
state_clear() {
    local f; f=$(_state_file "$1")
    if is_dry_run; then
        if [[ -n "${_STATE_SHADOW:-}" ]]; then
            rm -f "$_STATE_SHADOW/set/$1"
            : >"$_STATE_SHADOW/cleared/$1" \
                || { warn "state_clear: cannot write the dry-run shadow ${_STATE_SHADOW}"; return 1; }
        fi
        debug "[dry-run] state_clear $1"; return 0
    fi
    rm -f "$f"
}

mark_phase_done() { state_set "phase-${1}" "$(_ts)"; }
is_phase_done()   { state_has "phase-${1}"; }
clear_phase()     { state_clear "phase-${1}"; }

# phase_begin <num> <name> / phase_end <num>
# Bracket a phase so the exit trap can name the failing phase and resume is
# unambiguous. phase_begin records an in-progress marker; phase_end clears it
# and records the done marker.
phase_begin() {
    CURRENT_PHASE=$1; CURRENT_PHASE_NAME=$2
    state_set "current-phase" "${1}:${2}"
    step "Phase ${1} — ${2}"
}
phase_end() {
    mark_phase_done "$1"
    state_clear "current-phase"
    CURRENT_PHASE=""; CURRENT_PHASE_NAME=""
}

# ----------------------------------------------------------------------------
# Timestamped backups. Every file DeePloy edits is copied (perms preserved) to
# $BACKUP_DIR, path-preserved, once per run, before the first modification.
# ----------------------------------------------------------------------------
backup_file() {
    local path=$1 dest
    [[ -e "$path" ]] || return 0
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would back up $path"; return 0; fi
    dest="$BACKUP_DIR/${path#/}"
    [[ -e "$dest" ]] && return 0          # already captured this run
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
    printf '%s\n' "$path" >>"$BACKUP_DIR/MANIFEST"
    _log BACKUP "$path -> $dest"
    debug "backed up $path -> $dest"
}

# restore_file <path> — restore from THIS run's backup (rollback of risky steps).
restore_file() {
    local path=$1 src
    src="$BACKUP_DIR/${path#/}"
    [[ -e "$src" ]] || { warn "No backup for $path in run $RUN_TS"; return 1; }
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would restore $path"; return 0; fi
    cp -a "$src" "$path"; ok "Restored $path from backup"
}

# ----------------------------------------------------------------------------
# Idempotent file edits.
# ----------------------------------------------------------------------------
_ensure_parent() {
    local d; d=$(dirname "$1")
    [[ -d "$d" ]] && return 0
    is_dry_run && return 0
    mkdir -p "$d"
}

# _commit <file> <tmpfile> <description>
# Writes tmp -> file only if content differs. Backs up first. Preserves the
# existing file's perms/owner (content replace via redirection, not mv).
_commit() {
    local file=$1 tmp=$2 desc=$3
    if [[ -e "$file" ]] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; debug "no change: $file ($desc)"; return 0; fi
    if is_dry_run; then
        info "${C_DIM}[dry-run]${C_NC} would update $file ($desc)"
        [[ "$DEEPLOY_DEBUG" == "1" && -e "$file" ]] && diff -u "$file" "$tmp" >&2 || true
        rm -f "$tmp"; return 0
    fi
    [[ -e "$file" ]] && backup_file "$file"
    cat "$tmp" >"$file"
    rm -f "$tmp"
    ok "Updated $file ${C_DIM}($desc)${C_NC}"
}

# ensure_line <file> <line> [match_regex]
#   No match_regex : append <line> unless an identical line already exists.
#   With match_regex: replace the first line matching the regex with <line>
#                     (append if none match). Use for key=value style settings.
ensure_line() {
    local file=$1 line=$2 key=${3:-} tmp
    _ensure_parent "$file"
    tmp=$(_mktemp)
    if [[ -e "$file" ]]; then
        if [[ -n "$key" ]]; then
            if grep -qE -- "$key" "$file"; then
                grep -qxF -- "$line" "$file" && { rm -f "$tmp"; return 0; }
                awk -v key="$key" -v repl="$line" \
                    'BEGIN{d=0} {if(!d && $0 ~ key){print repl; d=1} else print} END{if(!d) print repl}' \
                    "$file" >"$tmp"
            else
                cat "$file" >"$tmp"; printf '%s\n' "$line" >>"$tmp"
            fi
        else
            grep -qxF -- "$line" "$file" && { rm -f "$tmp"; return 0; }
            cat "$file" >"$tmp"; printf '%s\n' "$line" >>"$tmp"
        fi
    else
        printf '%s\n' "$line" >"$tmp"
    fi
    _commit "$file" "$tmp" "ensure_line"
}

# ensure_kv <file> <key> <value> [sep]
#   Manage a "key<sep>value" line (sep defaults to "="). Replace-or-append.
#   Convenience wrapper over ensure_line for settings like DefaultLimitNOFILE=…
ensure_kv() {
    local file=$1 key=$2 val=$3 sep=${4:-=}
    ensure_line "$file" "${key}${sep}${val}" "^[[:space:]]*${key}[[:space:]]*${sep}"
}

# _mode_is_restrictive <octal-mode>
#   True ONLY for modes with no group/other READ bit (0600/0700/0400/0500/...).
#   0644 configs and 0755 scripts are NOT restrictive and keep the normal path,
#   so this narrows the umask hardening below to genuinely sensitive files.
_mode_is_restrictive() {
    local m=$1
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$m & 8#044) == 0 ))
}

# write_file <path> <content> [mode]
#   Dry-run-aware whole-file writer for generated artifacts (validator.sh, unit
#   files, sysctl drop-ins). Backs up any existing file, writes only on content
#   change, then applies mode. Modules use this instead of a raw `> file` so no
#   side effect can bypass backup/dry-run. Content should include its own
#   trailing newline.
#
#   S3: for a RESTRICTIVE mode (e.g. the 0600 conf), a sensitive file must never
#   be group/world-readable for even an instant. _commit replaces content in
#   place (cat > file), which preserves a pre-existing dest's looser perms and,
#   for a fresh file, is born world-readable under the default umask — both leave
#   a TOCTOU window before the trailing chmod. So: chmod the existing dest down
#   FIRST, and run the create+commit under ( umask 077 ) so a fresh file is born
#   0600. The subshell scopes the umask (auto-restored); _commit's side effects
#   (backup copy, content write, logging) are all external, so nothing is lost.
write_file() {
    local path=$1 content=$2 mode=${3:-} tmp
    _ensure_parent "$path"
    tmp=$(_mktemp); printf '%s' "$content" >"$tmp"
    if [[ -n "$mode" ]] && _mode_is_restrictive "$mode"; then
        if [[ -e "$path" ]] && ! is_dry_run; then chmod "$mode" "$path"; fi   # close the window on a looser existing dest
        ( umask 077; _commit "$path" "$tmp" "write_file" )                    # a fresh file is born 0600
    else
        _commit "$path" "$tmp" "write_file"
    fi
    [[ -n "$mode" ]] || return 0
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would chmod $mode $path"
    else chmod "$mode" "$path"; fi
}

# ensure_block <file> <id> <content>
#   Insert/replace a marker-guarded block. Re-runs replace the block in place.
#   Markers:  # >>> deeploy:<id> >>>   ...   # <<< deeploy:<id> <<<
#   Content (possibly multi-line) is passed to awk via a temp file + getline so
#   embedded newlines work on gawk, mawk, and BSD awk alike.
ensure_block() {
    local file=$1 id=$2 content=$3 tmp cf
    local begin="# >>> deeploy:${id} >>>" end="# <<< deeploy:${id} <<<"
    _ensure_parent "$file"
    cf=$(_mktemp); printf '%s\n' "$content" >"$cf"
    tmp=$(_mktemp)
    if [[ -e "$file" ]] && grep -qF -- "$begin" "$file"; then
        if ! awk -v b="$begin" -v e="$end" -v cf="$cf" '
            $0==b   { print b; while ((getline line < cf) > 0) print line; close(cf); print e; skip=1; next }
            skip && $0==e { skip=0; next }
            skip    { next }
                    { print }
        ' "$file" >"$tmp"; then
            rm -f "$tmp" "$cf"; warn "ensure_block: failed to rewrite $file"; return 1
        fi
    else
        # Build the full file fresh (read $file/$cf, write $tmp — never self-read).
        {
            if [[ -e "$file" ]]; then
                cat "$file"
                [[ -s "$file" ]] && printf '\n'   # separate appended block from prior content
            fi
            printf '%s\n' "$begin"
            cat "$cf"
            printf '%s\n' "$end"
        } >"$tmp"
    fi
    rm -f "$cf"
    _commit "$file" "$tmp" "block:${id}"
}

# remove_block <file> <id> — drop a previously inserted marker block (rollback).
remove_block() {
    local file=$1 id=$2 tmp
    local begin="# >>> deeploy:${id} >>>" end="# <<< deeploy:${id} <<<"
    [[ -e "$file" ]] && grep -qF -- "$begin" "$file" || return 0
    tmp=$(_mktemp)
    awk -v b="$begin" -v e="$end" '
        $0==b {skip=1; next} skip && $0==e {skip=0; next} skip {next} {print}
    ' "$file" >"$tmp"
    _commit "$file" "$tmp" "remove-block:${id}"
}

# ----------------------------------------------------------------------------
# GRUB drop-ins that replace the kernel cmdline.
# ----------------------------------------------------------------------------
# Measured, not assumed, on an Ubuntu 22.04 cloud image (arm64 — its drop-in sets
# console=ttyAMA0): grub-mkconfig sources /etc/default/grub at line 162 and then
# loops over /etc/default/grub.d/*.cfg at 164-167, sourcing each one AFTER. On
# that image 50-cloudimg-settings.cfg line 11 is a bare
# GRUB_CMDLINE_LINUX_DEFAULT="…" — a clobber, not an append. That is one image,
# not a claim about every Ubuntu image; the ORDERING is the part that generalises.
#
# Also measured on the same image: init-select.cfg sits in that directory and
# assigns nothing of the sort. Harmless drop-ins are ordinary, which is why phase
# 0 warns instead of blocking.
#
# Lives here rather than in preflight because phase 2 needs it too: when the
# read-back refuses, the operator should be told which drop-in is on THEIR box,
# derived at that moment, rather than a filename this repo remembered.
#
# An assignment that references the current value EXTENDS it and is left alone.
deeploy_grub_clobbering_dropins() {                # -> prints basenames, one per line
    local dir="${GRUB_D_DIR:-/etc/default/grub.d}" f line
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.cfg; do
        [[ -e "$f" ]] || continue
        while IFS= read -r line; do
            # shellcheck disable=SC2016  # the literal text is the subject: this reads
            # someone else's file and asks whether it names that variable.
            case "$line" in
                *'$GRUB_CMDLINE_LINUX_DEFAULT'*|*'${GRUB_CMDLINE_LINUX_DEFAULT'*) continue ;;
            esac
            printf '%s\n' "${f##*/}"; break
        done < <(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$f" 2>/dev/null || true)
    done
    return 0
}

# ----------------------------------------------------------------------------
# Traps. deeploy.sh must run `set -Eeuo pipefail` for the ERR trap to fire
# inside functions; this only installs the handlers.
# ----------------------------------------------------------------------------
# Pinpoint the failing command. Kept bulletproof (|| true, always-0 _log) so it
# can never re-enter the ERR trap; errexit is deliberately left intact here.
_deeploy_on_err() {
    local code=$? line=$1 cmd=$2
    printf '%s  [FAIL]%s line %s: [%s] (exit %s)\n' "$C_RED" "$C_NC" "$line" "$cmd" "$code" >&2 || true
    _log ERR "line $line: $cmd (exit $code)"
}
# On any non-zero exit, leave an actionable footer: which phase died, where the
# log + backups are, and how to resume. This is the rollback/resume safety net
# for a tool that edits grub/fstab/sysctl as root. set +e (after capturing the
# code) so the footer's own conditionals can't perturb the exit status.
_deeploy_on_exit() {
    local code=$?
    set +e
    # The dry-run state shadow goes on every exit, clean or not (R10-7e).
    if [[ -n "${_STATE_SHADOW:-}" ]]; then rm -rf -- "$_STATE_SHADOW"; _STATE_SHADOW=""; fi
    [[ $code -eq 0 ]] && return 0
    _log EXIT "exit $code phase=${CURRENT_PHASE:-?}(${CURRENT_PHASE_NAME:-?})"
    {
        printf '\n%s━━━ DeePloy aborted (exit %s) ━━━%s\n' "$C_RED" "$code" "$C_NC"
        [[ -n "$CURRENT_PHASE_NAME" ]] && printf '  Failed in phase %s (%s)\n' "$CURRENT_PHASE" "$CURRENT_PHASE_NAME"
        [[ -n "${LOG_FILE:-}" ]] && printf '  Log:      %s\n' "$LOG_FILE"
        if [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR:-}" ]]; then
            printf '  Backups:  %s\n' "$BACKUP_DIR"
            printf '            (system files were copied here before edits — restore from this dir)\n'
        fi
        printf '  Resume:   %s install --resume\n' "${DEEPLOY_CMD:-$DEEPLOY_SELF}"
    } >&2
    return 0
}
deeploy_init_traps() {
    trap '_deeploy_on_err "$LINENO" "$BASH_COMMAND"' ERR
    trap '_deeploy_on_exit' EXIT
    trap 'fail "Interrupted (SIGINT/SIGTERM)"' INT TERM
}

# Report inability to create /opt/deeploy. Two very different situations:
#   non-root (tests, ad-hoc exploration) -> expected, degrade quietly;
#   root (read-only filesystem / disk full) -> serious: state tracking, resume,
#   and backups are all disabled, so say so loudly.
# Factored out (takes is_root 0/1) so both branches are unit-testable off-root.
_common_statedir_unavailable() {
    if [[ "$1" == "1" ]]; then
        warn "Running as root but CANNOT create ${STATE_DIR} — read-only filesystem or disk full?"
        warn "State tracking, resume, and backups are DISABLED. Fix the filesystem before a real install."
    else
        info "Not root: /opt/deeploy unavailable — logging to console only (fine for audit/dry exploration)"
    fi
}

# ----------------------------------------------------------------------------
# common_init — call once from deeploy.sh AFTER flags are parsed.
# Resolves directories (env-overridable for tests), creates them (skipped in
# dry-run: its state goes to a temp shadow instead), decides interactivity,
# and opens the log.
# ----------------------------------------------------------------------------
common_init() {
    RUN_TS="${RUN_TS:-$(_ts_run)}"
    STATE_DIR="${DEEPLOY_STATE_DIR:-/opt/deeploy/state}"
    BACKUP_ROOT="${DEEPLOY_BACKUP_DIR:-/opt/deeploy/backups}"
    BACKUP_DIR="$BACKUP_ROOT/$RUN_TS"
    LOG_DIR="${DEEPLOY_LOG_DIR:-/opt/deeploy/logs}"

    # POST_REBOOT (systemd resume) and a closed stdin both imply non-interactive.
    [[ "$POST_REBOOT" == "1" ]] && NONINTERACTIVE=1
    if [[ -z "$NONINTERACTIVE" ]]; then
        if [[ -t 0 && -t 1 ]]; then NONINTERACTIVE=0; else NONINTERACTIVE=1; fi
    fi

    if is_dry_run; then
        LOG_FILE=""   # dry-run writes no log: console only
    elif mkdir -p "$STATE_DIR/state.d" "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null; then
        LOG_FILE="${DEEPLOY_LOG_FILE:-$LOG_DIR/deeploy-$RUN_TS.log}"
    else
        # Never point LOG_FILE at an uncreatable path or every _log redirection
        # leaks an open error. Degrade to console-only, distinguishing the
        # expected non-root case from a serious root-side filesystem fault.
        LOG_FILE=""
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then _common_statedir_unavailable 1; else _common_statedir_unavailable 0; fi
    fi
    _init_colors
    # After the colors, so a refusal prints like any other.
    if is_dry_run; then _state_shadow_init; fi
    _log INIT "DeePloy v$DEEPLOY_VERSION run=$RUN_TS dry_run=$DRY_RUN noninteractive=$NONINTERACTIVE post_reboot=$POST_REBOOT"
    debug "STATE_DIR=$STATE_DIR BACKUP_DIR=$BACKUP_DIR LOG_FILE=${LOG_FILE:-<none>}"
}
