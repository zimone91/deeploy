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
DEEPLOY_VERSION="${DEEPLOY_VERSION:-0.1.0}"

# How to invoke DeePloy in printed instructions. There is no `deeploy` in PATH —
# the operator runs the script by path. deeploy.sh sets DEEPLOY_SELF (its own
# absolute path); prefer that, else fall back to the relative invocation. Used in
# all operator-facing "run: <cmd> dz-connect/export/…" text.
DEEPLOY_CMD="${DEEPLOY_CMD:-${DEEPLOY_SELF:-./deeploy.sh}}"

: "${DRY_RUN:=0}"          # 1 = print plan, change nothing
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
    [[ -f "$file" ]] || { warn "sysctl file not found: $file"; return 0; }
    if is_dry_run; then info "${C_DIM}[dry-run]${C_NC} would apply sysctl keys from $file (tolerant)"; return 0; fi
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
# Read-only operations work even under --dry-run; writes are no-ops in dry-run.
# ----------------------------------------------------------------------------
_state_file() { printf '%s/state.d/%s' "$STATE_DIR" "$1"; }

state_set() {
    local key=$1 val=$2 f; f=$(_state_file "$key")
    is_dry_run && { debug "[dry-run] state_set $key=$val"; return 0; }
    mkdir -p "$(dirname "$f")" && printf '%s' "$val" >"$f"
    debug "state_set $key=$val"
}
state_get() { local key=$1 def=${2:-} f; f=$(_state_file "$key"); [[ -f "$f" ]] && cat "$f" || printf '%s' "$def"; }
state_has() { [[ -f "$(_state_file "$1")" ]]; }
state_clear() {
    local f; f=$(_state_file "$1")
    is_dry_run && { debug "[dry-run] state_clear $1"; return 0; }
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
# dry-run so nothing is written), decides interactivity, and opens the log.
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
        LOG_FILE=""   # dry-run changes nothing on disk: console only
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
    _log INIT "DeePloy v$DEEPLOY_VERSION run=$RUN_TS dry_run=$DRY_RUN noninteractive=$NONINTERACTIVE post_reboot=$POST_REBOOT"
    debug "STATE_DIR=$STATE_DIR BACKUP_DIR=$BACKUP_DIR LOG_FILE=${LOG_FILE:-<none>}"
}
