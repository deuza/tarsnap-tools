#!/bin/sh
#
# N-R2-3: when the night of DOW or DOM was missed, nothing represented that
# week or that month any more. The first archive of the period now stands
# in for it, in tarsnap-backup.sh as in rotation-check.sh, whose replay
# also warns when the newest archive is two days old or more.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
FAKE_NOW="2026-10-22 00:02:00"
days www 2026-01-01 294 00-02-00 |
    grep -v -e '^www-2026-03-01_' -e '^www-2026-06-15_' > "$T/list"

set_archives < "$T/list"
run_backup --dry-run --verbose
expect_rc 0
grep -q '^Monthly .* kept: www-2026-03-02_00-02-00$' "$T/out" ||
    fail "backup: 2026-03-02 does not stand in for the month"
grep -q '^Weekly .* kept: www-2026-06-16_00-02-00$' "$T/out" ||
    fail "backup: 2026-06-16 does not stand in for the week"

run_rotation -l "$T/list"
expect_rc 0 "rotation-check.sh -l"
grep -q '^  www-2026-03-02_00-02-00 *KEPT  (grandfather, monthly)$' "$T/out" ||
    fail "rotation-check.sh: 2026-03-02 does not stand in for the month"
grep -q '^  www-2026-06-16_00-02-00 *KEPT  (father, weekly)$' "$T/out" ||
    fail "rotation-check.sh: 2026-06-16 does not stand in for the week"

FAKE_NOW="2026-10-25 12:00:00"
run_rotation -l "$T/list"
expect_out "WARNING: the newest archive, www-2026-10-21_00-02-00, is 4 days old:"

t_done
