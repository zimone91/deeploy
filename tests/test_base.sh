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

echo "== base_firewall (lockout-safety ordering) =="
: >"$CALLS"; SSH_PORT=2222 base_firewall >/dev/null 2>&1
LIMLN=$(grep -n 'ufw limit 2222/tcp' "$CALLS" | cut -d: -f1)
ENLN=$(grep -n 'ufw --force enable' "$CALLS" | cut -d: -f1)
check_true "SSH limited BEFORE ufw enable" "[[ ${LIMLN:-0} -lt ${ENLN:-0} ]]"
check "default deny incoming" "$(grep -c 'ufw default deny incoming' "$CALLS")" "1"
check "gossip 8001/tcp"       "$(grep -c 'ufw allow 8001/tcp' "$CALLS")"        "1"
check "gossip 8001/udp"       "$(grep -c 'ufw allow 8001/udp' "$CALLS")"        "1"
check "dynamic 8900:9000/udp" "$(grep -c 'ufw allow 8900:9000/udp' "$CALLS")"   "1"
check "public 8899 NOT opened"   "$(grep -c '8899' "$CALLS")" "0"
check "public 8900/tcp NOT opened" "$(grep -c '8900/tcp' "$CALLS")" "0"

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
state_set dz_enabled true; : >"$CALLS"; SSH_PORT=2222 base_firewall >/dev/null 2>&1
check "DZ fw: GRE rule"        "$(grep -c 'ufw allow proto gre' "$CALLS")" "1"
check "DZ fw: BGP 179 in+out"  "$(grep -c 'on doublezero0 from 169.254.0.0/16 to 169.254.0.0/16 port 179 proto tcp' "$CALLS")" "2"
check "DZ fw: 44880 udp in+out" "$(grep -c 'on doublezero0 to any port 44880 proto udp' "$CALLS")" "2"
DZ_GRELN=$(grep -n 'ufw allow proto gre' "$CALLS" | cut -d: -f1); DZ_ENLN=$(grep -n 'ufw --force enable' "$CALLS" | cut -d: -f1)
check_true "DZ fw rules BEFORE ufw enable" "[[ ${DZ_GRELN:-0} -lt ${DZ_ENLN:-0} ]]"
state_set dz_enabled false; : >"$CALLS"; SSH_PORT=2222 base_firewall >/dev/null 2>&1
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

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
