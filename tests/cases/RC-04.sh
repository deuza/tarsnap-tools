#!/bin/sh
#
# RC-04: an archive of the strict form whose date does not exist stopped
# the replay on an unset parameter, without a summary. It now gets a
# verdict of its own, as the backup keeps it, and the replay goes on.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
{
    days www 2026-06-01 5 00-02-02
    printf '%s\n' www-2026-02-30_00-02-02
} > "$T/list"

run_rotation -l "$T/list"
expect_rc 0
grep -q '^  www-2026-02-30_00-02-02 *impossible date, kept$' "$T/out" ||
    fail "no verdict for the impossible date"
expect_out "  outside the rotation   : 1"
expect_out "  kept in total          : 5"

t_done
