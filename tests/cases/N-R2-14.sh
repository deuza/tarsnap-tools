#!/bin/sh
#
# N-R2-14: when tarsnap -x failed, the copies extracted were compared all
# the same, though one may be partial: false "*" and even false "=". No
# copy is compared any more: the files to check are reported as modified,
# and the header of the log says why.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
printf 'same\n' > "$T/root/f"
snapshot snap1 "$T/root"
touch -d '2026-01-02 00:00:00' "$T/root/f"
printf '1\n' > "$S/x.rc"

run_diff snap1
expect_rc 0
expect_err 'WARNING: "tarsnap -x" returned 1: a copy may be partial, so none is'
LOG="$T/log/tarsnap-diff.sh-snap1.log"
grep -qxF "* $R/f" "$LOG" || fail "f is not reported as modified"
grep -qF '# extraction  : tarsnap -x failed (exit code 1), no copy compared,' "$LOG" ||
    fail "the header does not say that the extraction failed"

t_done
