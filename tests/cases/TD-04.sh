#!/bin/sh
#
# TD-04: tarsnap lists the second name of a file with several links as a
# hard link, type h with a size of 0, which tarsnap-diff.sh left out: it
# came out as new. A hard link now takes the size of its target and is
# compared as the regular file it is, its target extracted with it.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
printf 'abc\n' > "$T/root/h1"
ln "$T/root/h1" "$T/root/h2"
printf 'p\n' > "$T/root/p"
snapshot snap1 "$T/root"
LOG="$T/log/tarsnap-diff.sh-snap1.log"

run_diff snap1
expect_rc 0 "unchanged"
expect_out "deleted     (<) : 0"
expect_out "new         (>) : 0"
grep -qxF "= $R/h1" "$LOG" || fail "h1 is not identical"
grep -qxF "= $R/h2" "$LOG" || fail "h2 is not identical"

# The same size, another content and date: both names are modified.
printf 'xyz\n' > "$T/root/h1"
touch -d '2026-01-02 00:00:00' "$T/root/h1"
run_diff snap1
expect_rc 0 "modified"
grep -qxF "* $R/h1" "$LOG" || fail "h1 is not modified"
grep -qxF "* $R/h2" "$LOG" || fail "h2 is not modified"

rm "$T/root/h2"
run_diff snap1
expect_rc 0 "deleted"
grep -qxF "< $R/h2" "$LOG" || fail "the deletion of h2 is not reported"

t_done
