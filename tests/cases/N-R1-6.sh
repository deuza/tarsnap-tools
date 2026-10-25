#!/bin/sh
#
# N-R1-6: a clock moved ahead made the next run purge in a single call
# about one archive per day of shift. The purge circuit breaker stops it;
# rotation-check.sh warns of an archive dated after today, and tells after
# how many days ahead the next run would trip the breaker.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
days www 2026-03-13 89 00-02-02 > "$T/list"

set_archives < "$T/list"
run_backup
expect_rc 0 "clock right"
expect_calls d 0

set_archives < "$T/list"
FAKE_NOW="2026-08-10 12:00:00"
run_backup
expect_rc 1 "clock two months ahead"
expect_err "more than MAX_PURGE=7:"
expect_calls d 0

install_rotation
FAKE_NOW="2026-06-10 12:00:00"
{
    cat "$T/list"
    printf 'www-2026-06-12_00-02-02\n'
} > "$T/ahead"
run_rotation -l "$T/ahead"
expect_rc 0 "rotation-check.sh -l"
expect_out "WARNING: the newest archive, www-2026-06-12_00-02-02, is dated after today:"

FAKE_NOW="2026-10-25 12:00:00"
run_rotation
expect_out "it trips after 8 missed night(s) in a row, or with a"
expect_out "clock 8 day(s) ahead, deleting 8 (7 a day less)."

t_done
