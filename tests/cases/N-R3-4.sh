#!/bin/sh
#
# N-R3-4: the control bytes of a local name went raw into the log, so that
# reading it with cat or tail -f could erase a line or drive the terminal.
# They are written as "?" in the log and in the warnings.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
snapshot snap1 "$T/root"
ESC=$(printf '\033')
CR=$(printf '\r')
printf 'x\n' > "$T/root/evil${ESC}[2Jname${CR}"

run_diff snap1
expect_rc 0
LOG="$T/log/tarsnap-diff.sh-snap1.log"
grep -qxF "> $R/evil?[2Jname?" "$LOG" || fail "the name is not shown with ?"
if grep -q "[$ESC$CR]" "$LOG"; then
    fail "raw ESC or CR in the log"
fi

t_done
