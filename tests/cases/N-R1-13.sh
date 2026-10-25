#!/bin/sh
#
# N-R1-13: in the time zones where the change to summer time skips
# midnight, date -d "YYYY-MM-DD" fails for that day, and the purge stopped
# every night once an archive of that day existed. The dates are now taken
# from noon, which always exists, in tarsnap-backup.sh as in both modes of
# rotation-check.sh.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
TZ=America/Havana
FAKE_NOW="2026-04-10 12:00:00"
days www 2026-03-05 36 03-00-00 > "$T/list"
grep -qx 'www-2026-03-08_03-00-00' "$T/list" || fail "no archive of 2026-03-08"
set_archives < "$T/list"

run_backup --dry-run --verbose
expect_rc 0 "backup"
reject_err "invalid date"
reject_err "impossible date"
expect_out "Daily (0 to 90 days), kept: www-2026-03-08_03-00-00"

run_rotation -l "$T/list"
expect_rc 0 "rotation-check.sh -l"
grep -q '^  www-2026-03-08_03-00-00 *KEPT  (son, daily)$' "$T/out" ||
    fail "rotation-check.sh -l: no verdict for 2026-03-08"

run_rotation
expect_rc 0 "rotation-check.sh, simulation"
expect_out "All three tiers are active, the configuration is consistent."

t_done
