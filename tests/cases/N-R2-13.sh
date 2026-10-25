#!/bin/sh
#
# N-R2-13: both inventories gave local times, and in the hour repeated
# when the clocks go back, t and t + 3600 s print the same: a file of the
# same size rewritten one hour later came out identical. Both sides are
# now read in UTC.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
TZ=Europe/Paris
# 00:30 UTC and 01:30 UTC on 2026-10-25 are both 02:30 in Paris.
printf 'AAAA\n' > "$T/root/f"
touch -d '2026-10-25 00:30:00 UTC' "$T/root/f"
snapshot snap1 "$T/root"
printf 'BBBB\n' > "$T/root/f"
touch -d '2026-10-25 01:30:00 UTC' "$T/root/f"

run_diff snap1
expect_rc 0
expect_calls x 1
grep -qxF "* $R/f" "$T/log/tarsnap-diff.sh-snap1.log" ||
    fail "f is not reported as modified"

t_done
