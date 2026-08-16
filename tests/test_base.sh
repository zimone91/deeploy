#!/usr/bin/env bash
# Self-contained tests for lib/base.sh — no root, no apt, no network.
# apt-get/ufw/systemctl/ss are mocked and record their calls; sshd_config is a
# fixture. Covers the lockout-safety ordering and the SSH verify-or-rollback.
#
# Mocks shadow real commands and are invoked indirectly.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEEPLOY_STATE_DIR="$WORK/state" DEEPLOY_BACKUP_DIR="$WORK/backups" DEEPLOY_LOG_DIR="$WORK/logs"
export NONINTERACTIVE=1 DEEPLOY_COLOR=never

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/base.sh
source "$ROOT/lib/base.sh"

PASS=0; FAIL=0
check()       { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }
check_true()  { if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s (expr false: %s)\n' "$1" "$2"; fi; }
check_false() { if eval "$2"; then FAIL=$((FAIL+1)); printf '  FAIL %s (expr true: %s)\n' "$1" "$2"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }

DRY_RUN=0 common_init

CALLS="$WORK/calls"; : >"$CALLS"
apt-get()   { echo "apt-get $*"   >>"$CALLS"; return 0; }
ufw()       { echo "ufw $*"       >>"$CALLS"; return 0; }
systemctl() { echo "systemctl $*" >>"$CALLS"
    case "$*" in "is-enabled ssh.socket"|"is-active ssh.socket") return "${SOCKET_RC:-1}";; *) return 0;; esac; }
ss() { [[ -n "${SS_PORT_LISTENING:-}" ]] && printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$SS_PORT_LISTENING"; return 0; }
# Hermetic: a real sshd may exist on the test host (macOS/CI); force the N5
# effective-port read onto the deterministic file-parse fallback. The sshd -T
# path is tested explicitly with an emitting mock in the N5 section below.
sshd() { return 1; }

SSHN=0
fresh_sshd()      { SSHN=$((SSHN+1)); printf '%s\n' "$1" >"$WORK/sshd_$SSHN"; printf '%s' "$WORK/sshd_$SSHN"; }
fresh_sshd_full() { SSHN=$((SSHN+1)); local p="$WORK/sshd_$SSHN"
    printf '%s\n' "#Port 22" "#AddressFamily any" "#GatewayPorts no" "PermitRootLogin yes" >"$p"; printf '%s' "$p"; }

echo "== _valid_port =="
check_true  "22 valid"      "_valid_port 22"
check_true  "2222 valid"   "_valid_port 2222"
check_false "70000 invalid" "_valid_port 70000"
check_false "abc invalid"   "_valid_port abc"
check_false "0 invalid"     "_valid_port 0"

echo "== _sshd_configured_port =="
check "commented Port -> empty" "$(_sshd_configured_port "$(fresh_sshd '#Port 22')")" ""
check "active Port -> value"    "$(_sshd_configured_port "$(fresh_sshd 'Port 2222')")" "2222"

echo "== base_packages =="
: >"$CALLS"; BASE_APT_UPGRADE=true base_packages >/dev/null 2>&1
check "apt update"   "$(grep -c 'apt-get update' "$CALLS")"        "1"
check "apt upgrade"  "$(grep -c 'apt-get upgrade -y' "$CALLS")"    "1"
check "apt install"  "$(grep -c 'apt-get install -y' "$CALLS")"    "1"
check "install lists ufw"      "$(grep -c 'install -y .* ufw ' "$CALLS")"   "1"
check "install lists fail2ban" "$(grep -c 'install -y .*fail2ban' "$CALLS")" "1"
: >"$CALLS"; BASE_APT_UPGRADE=false base_packages >/dev/null 2>&1
check "upgrade skipped when disabled" "$(grep -c 'apt-get upgrade' "$CALLS")" "0"
: >"$CALLS"; DRY_RUN=1 base_packages >/dev/null 2>&1; DRY_RUN=0
check "dry-run issues no apt calls" "$(wc -l <"$CALLS" | tr -d ' ')" "0"

echo "== apt upgrade fires once, never on re-run (live-node safety) =="
state_clear base_apt_upgraded
: >"$CALLS"; BASE_APT_UPGRADE=true base_packages >/dev/null 2>&1
check "first run upgrades"             "$(grep -c 'apt-get upgrade -y' "$CALLS")" "1"
check_true "upgrade marker recorded"   "state_has base_apt_upgraded"
: >"$CALLS"; BASE_APT_UPGRADE=true base_packages >/dev/null 2>&1
check "re-run skips upgrade (marker)"  "$(grep -c 'apt-get upgrade' "$CALLS")"   "0"
check "re-run still installs"          "$(grep -c 'apt-get install -y' "$CALLS")" "1"

echo "== base_firewall (lockout-safety ordering; opens the CONFIGURED ssh port) =="
FW=$(fresh_sshd 'Port 2222'); state_clear ssh_port
: >"$CALLS"; SSHD_CONFIG="$FW" base_firewall >/dev/null 2>&1
LIMLN=$(grep -n 'ufw limit 2222/tcp' "$CALLS" | cut -d: -f1)
ENLN=$(grep -n 'ufw --force enable' "$CALLS" | cut -d: -f1)
check_true "SSH limited BEFORE ufw enable" "[[ ${LIMLN:-0} -lt ${ENLN:-0} ]]"
check "default deny incoming" "$(grep -c 'ufw default deny incoming' "$CALLS")" "1"
check "gossip 8001/tcp"       "$(grep -c 'ufw allow 8001/tcp' "$CALLS")"        "1"
check "gossip 8001/udp"       "$(grep -c 'ufw allow 8001/udp' "$CALLS")"        "1"
check "dynamic 8900:9000/udp" "$(grep -c 'ufw allow 8900:9000/udp' "$CALLS")"   "1"
check "public 8899 NOT opened"   "$(grep -c '8899' "$CALLS")" "0"
check "public 8900/tcp NOT opened" "$(grep -c '8900/tcp' "$CALLS")" "0"
check "realized ssh_port recorded post-success" "$(state_get ssh_port)" "2222"

echo "== P12: firewall honors overridable GOSSIP_PORT / DYNAMIC_PORT_RANGE =="
FP=$(fresh_sshd 'Port 2222'); state_clear ssh_port
: >"$CALLS"; GOSSIP_PORT=8101 DYNAMIC_PORT_RANGE=8910-9010 SSHD_CONFIG="$FP" base_firewall >/dev/null 2>&1
check "gossip override 8101/tcp"      "$(grep -c 'ufw allow 8101/tcp' "$CALLS")" "1"
check "gossip override 8101/udp"      "$(grep -c 'ufw allow 8101/udp' "$CALLS")" "1"
check "dynamic range colon-converted" "$(grep -c 'ufw allow 8910:9010/udp' "$CALLS")" "1"
check "default 8001 NOT used under override" "$(grep -c '8001' "$CALLS")" "0"

echo "== DoubleZero in Phase 1: early prompt + packages/env + firewall (gated on dz_enabled) =="
# Source doublezero.sh so base's declare-F-guarded DZ calls resolve. Mock the DZ
# commands the prepare path shells out to.
# shellcheck source-path=SCRIPTDIR source=../lib/doublezero.sh
source "$ROOT/lib/doublezero.sh"
curl() { local i j o=""; for ((i=1;i<=$#;i++)); do [[ "${!i}" == "-o" ]] && { j=$((i+1)); o="${!j}"; }; done; [[ -n "$o" ]] && : >"$o"; echo "curl $*" >>"$CALLS"; }
bash() { echo "bash $*" >>"$CALLS"; }            # the DZ setup.deb.sh
doublezero() { echo "doublezero $*" >>"$CALLS"; }
find() { command find "$@" 2>/dev/null; }
export DZ_OVERRIDE_CONF="$WORK/dz-override.conf"

# (a) early enable prompt — env preset honored, recorded to state, VISIBLE (not redirected)
state_clear dz_enabled
EOUT=$( DZ_ENABLED=true _base_resolve_config 2>&1 )
check "early prompt: dz_enabled recorded true" "$(state_get dz_enabled)" "true"
check "early prompt: prints the 'have your ID handy' line (visible)" "$(grep -c 'place it in Phase 5' <<<"$EOUT")" "1"
state_clear dz_enabled
( unset DZ_ENABLED; NONINTERACTIVE=1 _base_resolve_config ) >/dev/null 2>&1
check "early prompt: unset+non-interactive -> false" "$(state_get dz_enabled)" "false"
ask() { REPLY=y; }
state_clear dz_enabled
( unset DZ_ENABLED; ASSUME_YES=0 NONINTERACTIVE=0 SSH_PORT=2222 _base_resolve_config ) >/dev/null 2>&1
check "early prompt: interactive 'y' -> true" "$(state_get dz_enabled)" "true"
unset -f ask

# (b) base_packages installs DZ packages + env when dz_enabled
state_set dz_enabled true; : >"$CALLS"; BASE_APT_UPGRADE=false base_packages >/dev/null 2>&1
check "DZ enabled: doublezero pkgs installed" "$(grep -c 'apt-get install -y doublezero doublezero-solana' "$CALLS")" "1"
check "DZ enabled: doublezerod enabled boot"  "$(grep -c 'systemctl enable doublezerod' "$CALLS")" "1"
check "DZ enabled: env mainnet-beta+metrics"  "$(grep -c 'env mainnet-beta -metrics-enable' "$DZ_OVERRIDE_CONF")" "1"
state_set dz_enabled false; : >"$CALLS"; BASE_APT_UPGRADE=false base_packages >/dev/null 2>&1
check "DZ disabled: no doublezero pkg install" "$(grep -c 'doublezero doublezero-solana' "$CALLS")" "0"

# (c) base_firewall adds DZ rules when dz_enabled, none when not
state_set dz_enabled true; FDZ=$(fresh_sshd 'Port 2222'); state_clear ssh_port
: >"$CALLS"; SSHD_CONFIG="$FDZ" base_firewall >/dev/null 2>&1
check "DZ fw: GRE rule"        "$(grep -c 'ufw allow proto gre' "$CALLS")" "1"
check "DZ fw: BGP 179 in+out"  "$(grep -c 'on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp' "$CALLS")" "2"
check "DZ fw: 44880 udp in+out" "$(grep -c 'on doublezero0 to any port 44880 proto udp' "$CALLS")" "2"
DZ_GRELN=$(grep -n 'ufw allow proto gre' "$CALLS" | cut -d: -f1); DZ_ENLN=$(grep -n 'ufw --force enable' "$CALLS" | cut -d: -f1)
check_true "DZ fw rules BEFORE ufw enable" "[[ ${DZ_GRELN:-0} -lt ${DZ_ENLN:-0} ]]"
state_set dz_enabled false; FDZ2=$(fresh_sshd 'Port 2222'); state_clear ssh_port
: >"$CALLS"; SSHD_CONFIG="$FDZ2" base_firewall >/dev/null 2>&1
check "DZ disabled: no GRE rule" "$(grep -c 'proto gre' "$CALLS")" "0"
check "DZ disabled: no doublezero0 rules" "$(grep -c 'doublezero0' "$CALLS")" "0"
unset -f curl bash doublezero find
state_clear dz_enabled

echo "== base_ssh_port success path =="
F=$(fresh_sshd_full); : >"$CALLS"
SS_PORT_LISTENING=2222 SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port >/dev/null 2>&1
check "Port set active"          "$(_sshd_configured_port "$F")"          "2222"
check "exactly one active Port"  "$(grep -cE '^Port ' "$F")"              "1"
check "GatewayPorts untouched"   "$(grep -c '#GatewayPorts no' "$F")"     "1"
check "ssh restarted"            "$(grep -c 'systemctl restart ssh' "$CALLS")" "1"

echo "== socket -> service switch when ssh.socket present =="
F=$(fresh_sshd_full); : >"$CALLS"
SS_PORT_LISTENING=2222 SOCKET_RC=0 ASSUME_YES=1 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port >/dev/null 2>&1
check "ssh.socket disabled" "$(grep -c 'systemctl disable --now ssh.socket' "$CALLS")" "1"

echo "== already configured -> no restart =="
F=$(fresh_sshd 'Port 2222'); : >"$CALLS"
SS_PORT_LISTENING=2222 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port >/dev/null 2>&1
check "no restart when already set+listening" "$(grep -c restart "$CALLS")" "0"

echo "== dry-run: no sshd edit, no calls =="
F=$(fresh_sshd_full); : >"$CALLS"
DRY_RUN=1 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port >/dev/null 2>&1; DRY_RUN=0
check "dry-run leaves config unmodified" "$(_sshd_configured_port "$F")" ""
check "dry-run issues no calls"          "$(wc -l <"$CALLS" | tr -d ' ')" "0"

echo "== verify failure -> rollback + non-zero exit =="
F=$(fresh_sshd_full); : >"$CALLS"
( SS_PORT_LISTENING=22 SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port ) >/dev/null 2>&1
RC=$?
check "rollback exits non-zero"               "$RC" "1"
check "config restored (no active Port 2222)" "$(_sshd_configured_port "$F")" ""
check "original #Port 22 restored"            "$(grep -c '#Port 22' "$F")" "1"

echo "== X5: ss unavailable -> fail-closed (no false 'listening', rollback) =="
# Simulate ss absent by overriding `have` for ss only (real for everything else).
( have() { [[ "$1" == ss ]] && return 1; command -v "$1" >/dev/null 2>&1; }
  _ssh_listening_on 2222 ) >/dev/null 2>&1
check "ss absent -> _ssh_listening_on returns 1 (fail-closed)" "$?" "1"
# The base_ssh_port verify path must then ROLL BACK — even though SS_PORT_LISTENING
# says 2222 is up, an unverifiable check must not report success.
F=$(fresh_sshd_full); : >"$CALLS"
( have() { [[ "$1" == ss ]] && return 1; command -v "$1" >/dev/null 2>&1; }
  SS_PORT_LISTENING=2222 SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2222 SSHD_CONFIG="$F" base_ssh_port ) >/dev/null 2>&1
RC=$?
check "ss absent -> base_ssh_port rolls back (non-zero)"    "$RC" "1"
check "ss absent -> config restored (no active Port 2222)"  "$(_sshd_configured_port "$F")" ""
# ss PRESENT + listening -> proven S1 path unchanged: returns 0.
SS_PORT_LISTENING=2222
( _ssh_listening_on 2222 ) >/dev/null 2>&1
check "ss present + listening -> rc 0 (proven path unchanged)" "$?" "0"

echo "== N5: _sshd_effective_ports — sshd -T preferred, active-line file fallback =="
sshd() { case "${1:-}" in -T) printf 'port 2222\n';; *) return 1;; esac; }
check "sshd -T single port"        "$(_sshd_effective_ports /nonexistent | tr '\n' ' ')" "2222 "
sshd() { case "${1:-}" in -T) printf 'port 22\nport 2222\n';; *) return 1;; esac; }
check "sshd -T multiple ports"     "$(_sshd_effective_ports /nonexistent | tr '\n' ' ')" "22 2222 "
sshd() { return 1; }               # back to the hermetic fallback
FEP=$(fresh_sshd $'Port 2222\nPort 2244')
check "fallback: ALL active Port lines" "$(_sshd_effective_ports "$FEP" | tr '\n' ' ')" "2222 2244 "
FEP2=$(fresh_sshd '#Port 22')
check "fallback: commented-only -> empty" "$(_sshd_effective_ports "$FEP2")" ""

echo "== N5 write side: exactly ONE Port directive; canonical files byte-identical =="
# canonical stock image (#Port 22 + friends): the new all-lines edit must yield
# the SAME BYTES the old first-match ensure_line edit produced (proven path).
FBI=$(fresh_sshd_full)
printf '%s\n' "Port 2222" "#AddressFamily any" "#GatewayPorts no" "PermitRootLogin yes" >"$WORK/expected_canon"
_sshd_write_port "$FBI" 2222 >/dev/null 2>&1
check_true "canonical #Port-22 image -> byte-identical to the old edit" "cmp -s \"$FBI\" \"$WORK/expected_canon\""
# canonical single ACTIVE Port image: in-place value swap, byte-identical.
FB2=$(fresh_sshd 'Port 2222')
printf 'Port 2244\n' >"$WORK/expected_single"
_sshd_write_port "$FB2" 2244 >/dev/null 2>&1
check_true "canonical single-Port image -> byte-identical in-place swap" "cmp -s \"$FB2\" \"$WORK/expected_single\""
# THE N5 image (#Port 22 + provider-appended Port 2222): the old edit rewrote
# the comment and left TWO active directives; now it collapses to exactly one.
FB3=$(fresh_sshd $'#Port 22\nPort 2222')
_sshd_write_port "$FB3" 2244 >/dev/null 2>&1
check "N5 image: exactly ONE active Port after edit" "$(grep -cE '^Port ' "$FB3")" "1"
check "N5 image: no commented Port remains"          "$(grep -c '#Port' "$FB3")" "0"
check "N5 image: it is the new port"                 "$(grep -c '^Port 2244$' "$FB3")" "1"
# no Port line at all -> single directive appended
FB4=$(fresh_sshd 'PermitRootLogin yes')
_sshd_write_port "$FB4" 2222 >/dev/null 2>&1
check "no-Port file: single directive appended"      "$(grep -cE '^Port ' "$FB4")" "1"

echo "== N5 gate: multiple effective ports -> typed-yes gate; single port -> no gate =="
# Controllable require_yes mock: records the gate firing; GATE_RC = the answer.
require_yes() { echo "GATE:$1" >>"$CALLS"; return "${GATE_RC:-0}"; }
GATE_RC=0
# rc1-damaged image: TWO active ports. Refuse -> abort, file untouched.
FDMG=$(fresh_sshd $'Port 2222\nPort 2244')
GATE_RC=1
( SS_PORT_LISTENING=2255 SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2255 SSHD_CONFIG="$FDMG" base_ssh_port ) >/dev/null 2>&1
check "gate refused -> base_ssh_port aborts"      "$?" "1"
check "gate refused -> file untouched (2 ports)"  "$(grep -cE '^Port ' "$FDMG")" "2"
# Confirm -> edit collapses to ONE directive; firewall then opens that one.
GATE_RC=0; : >"$CALLS"
SS_PORT_LISTENING=2255 SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2255 SSHD_CONFIG="$FDMG" base_ssh_port >/dev/null 2>&1
check "gate fired once (require_yes consulted)"   "$(grep -c '^GATE:' "$CALLS")" "1"
check "confirmed: exactly one active Port"        "$(grep -cE '^Port ' "$FDMG")" "1"
check "confirmed: it is the new port 2255"        "$(grep -c '^Port 2255$' "$FDMG")" "1"
state_clear ssh_port; state_clear dz_enabled; : >"$CALLS"
SSHD_CONFIG="$FDMG" base_firewall >/dev/null 2>&1
check "firewall: limits the single sshd port"     "$(grep -c 'ufw limit 2255/tcp' "$CALLS")" "1"
check "firewall: no gate on a single port"        "$(grep -c '^GATE:' "$CALLS")" "0"
# Edit skipped/declined on a multi-port image -> base_firewall's OWN gate.
FDM2=$(fresh_sshd $'Port 2222\nPort 2244'); state_clear ssh_port
GATE_RC=1; : >"$CALLS"
( SSHD_CONFIG="$FDM2" base_firewall ) >/dev/null 2>&1
check "firewall multi-port + refuse -> abort"     "$?" "1"
check "firewall multi-port + refuse: NOT enabled" "$(grep -c 'force enable' "$CALLS")" "0"
GATE_RC=0; : >"$CALLS"
SSHD_CONFIG="$FDM2" base_firewall >/dev/null 2>&1
check "firewall multi-port + confirm: BOTH ports limited" "$(grep -cE 'ufw limit 22(22|44)/tcp' "$CALLS")" "2"
check "firewall multi-port: first recorded to state"      "$(state_get ssh_port)" "2222"
GATE_RC=0

echo "== N14: the listener check requires sshd when the process column is visible =="
ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n'; }
( _ssh_listening_on 2222 ) >/dev/null 2>&1
check "foreign daemon on the port -> NOT listening (rc1)" "$?" "1"
ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=7,fd=3))\n'; }
( _ssh_listening_on 2222 ) >/dev/null 2>&1
check "sshd on the port -> rc0"                           "$?" "0"
ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n'; }
( _ssh_listening_on 2222 ) >/dev/null 2>&1
check "no process info -> port-only pass (today's behavior)" "$?" "0"
( _ssh_listening_on 9999 ) >/dev/null 2>&1
check "port not present -> rc1"                           "$?" "1"
# and the verify-or-rollback gate actually ROLLS BACK on a foreign daemon
ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n'; }
FN14=$(fresh_sshd_full); : >"$CALLS"
( SOCKET_RC=1 ASSUME_YES=1 SSH_PORT=2222 SSHD_CONFIG="$FN14" base_ssh_port ) >/dev/null 2>&1
check "foreign daemon -> base_ssh_port rolls back (rc1)"  "$?" "1"
check "foreign daemon -> config restored (no active Port)" "$(_sshd_configured_port "$FN14")" ""
# restore the suite's standard ss mock for the sections below
ss() { [[ -n "${SS_PORT_LISTENING:-}" ]] && printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$SS_PORT_LISTENING"; return 0; }

echo "== S1: declined port change must NOT lock out (firewall opens the LIVE port) =="
# Operator is prompted to move 22->9999 but declines: sshd stays on 22, so the
# firewall must open 22 (the live port), never the unapplied 9999, and state must
# not record 9999. This is the interactive-"n" path the ASSUME_YES suite missed.
FD=$(fresh_sshd '#Port 22'); state_clear ssh_port; state_clear dz_enabled
confirm() { return 1; }                      # operator answers "n"
( SS_PORT_LISTENING="" SSH_PORT=9999 SSHD_CONFIG="$FD" base_ssh_port ) >/dev/null 2>&1
check "decline: sshd_config Port unchanged"        "$(_sshd_configured_port "$FD")" ""
check "decline: ssh_port NOT recorded as 9999"     "$(state_get ssh_port '<unset>')" "<unset>"
: >"$CALLS"; SSHD_CONFIG="$FD" base_firewall >/dev/null 2>&1
check "decline: firewall limits 22 (live), not 9999" "$(grep -c 'ufw limit 22/tcp' "$CALLS")" "1"
check "decline: firewall never references 9999"      "$(grep -c '9999' "$CALLS")" "0"
unset -f confirm

echo "== I7: re-run with a changed port deletes the stale old SSH rule =="
FI=$(fresh_sshd 'Port 2244'); state_set ssh_port 2222; state_clear dz_enabled   # prior realized port 2222
: >"$CALLS"; SSHD_CONFIG="$FI" base_firewall >/dev/null 2>&1
check "stale old-port rule deleted" "$(grep -c 'ufw delete limit 2222/tcp' "$CALLS")" "1"
check "new port limited"            "$(grep -c 'ufw limit 2244/tcp' "$CALLS")" "1"
check "realized ssh_port updated"   "$(state_get ssh_port)" "2244"
FI2=$(fresh_sshd 'Port 2244'); state_set ssh_port 2244
: >"$CALLS"; SSHD_CONFIG="$FI2" base_firewall >/dev/null 2>&1
check "no delete when port unchanged" "$(grep -c 'ufw delete' "$CALLS")" "0"

echo "== N15: fail2ban sshd jail follows the realized SSH port =="
export FAIL2BAN_JAIL_LOCAL="$WORK/jail.local"
FJ=$(fresh_sshd 'Port 2222'); state_clear ssh_port; state_clear dz_enabled
: >"$CALLS"; SSHD_CONFIG="$FJ" base_firewall >/dev/null 2>&1
check "jail.local rendered with the realized port" "$(grep -c '^port = 2222$' "$FAIL2BAN_JAIL_LOCAL")" "1"
check "jail targets [sshd]"                        "$(grep -c '^\[sshd\]$' "$FAIL2BAN_JAIL_LOCAL")" "1"
check "fail2ban reloaded to pick the jail up"      "$(grep -c 'systemctl reload-or-restart fail2ban' "$CALLS")" "1"
FJ2=$(fresh_sshd '#Port 22'); state_clear ssh_port
SSHD_CONFIG="$FJ2" base_firewall >/dev/null 2>&1
check "default port -> still explicit 'port = 22'" "$(grep -c '^port = 22$' "$FAIL2BAN_JAIL_LOCAL")" "1"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
