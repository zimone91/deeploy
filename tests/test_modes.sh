#!/usr/bin/env bash
# The executable bit is part of what ships, and nothing here used to check it.
#
# `git archive` packs tracked files and preserves INDEX modes, so a deeploy.sh
# recorded 100644 unpacks non-executable from the release tarball and the
# README's own first command, ./deeploy.sh, fails. v0.1.0-rc6 shipped exactly
# that.
#
# The failed command is the mild half. install writes a systemd unit whose
# ExecStart is that same path, and `systemctl enable` does not look at the bit —
# so the real failure lands at boot, as status=203/EXEC, after the reboot, on a
# box whose disks were erased three phases earlier.
#
# Two ways to measure, because the file is consumed in two places and both are
# real: inside a checkout the INDEX mode is what git archive will write; inside
# an unpacked tarball there is no index and the filesystem mode IS the shipped
# mode. Neither branch is a skip, and the suite says which one it used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$3" "$2"; fi; }

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE="git index"
    mode_of() { git -C "$ROOT" ls-files -s -- "$1" | awk '{print substr($1,4)}'; }
else
    SOURCE="unpacked files"
    mode_of() { stat -c %a "$ROOT/$1" 2>/dev/null || stat -f %Lp "$ROOT/$1" 2>/dev/null; }
fi
echo "== modes, measured from the ${SOURCE} =="

# Prove the measurement works before reporting on it. A mode_of that returned
# nothing would make every "is not executable" assertion below pass.
check "the measurement produces a mode at all" "$(mode_of deeploy.sh | grep -cE '^[0-7]{3,4}$')" "1"

# "unmeasured" rather than "no" when the mode cannot be read: the controls below
# expect "no", and an untracked or missing file would otherwise satisfy them
# without anything having been measured.
x_bit() {
    local m; m=$(mode_of "$1")
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || { echo "unmeasured"; return 0; }
    if (( (8#$m & 0111) != 0 )); then echo yes; else echo no; fi
}

# The entry point. Documented as ./deeploy.sh in README and used verbatim as the
# resume unit's ExecStart.
check "deeploy.sh is executable"   "$(x_bit deeploy.sh)"   "yes"
# Documented as ./run_tests.sh in CONTRIBUTING; it was already 755 and must stay.
check "run_tests.sh is executable" "$(x_bit run_tests.sh)" "yes"

# Controls, the other way. Without these, a check that called everything
# executable would pass both assertions above. lib/*.sh are SOURCED, never run,
# and the config example is data.
check "lib/common.sh is NOT executable"       "$(x_bit lib/common.sh)"       "no"
check "lib/disk.sh is NOT executable"         "$(x_bit lib/disk.sh)"         "no"
check "deeploy.conf.example is NOT executable" "$(x_bit deeploy.conf.example)" "no"
check "README.md is NOT executable"           "$(x_bit README.md)"           "no"
# And the predicate must be able to SAY it measured nothing, so that "no" above
# means a mode was read and had no x bit — not that the file was absent.
check "a path that is not there reads as unmeasured" "$(x_bit no/such/file.sh)" "unmeasured"

echo ""
echo "==================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
