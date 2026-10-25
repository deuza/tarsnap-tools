#!/bin/sh
#
# TB-04: a name of the strict form whose date does not exist stopped the
# rotation every night. tarsnap-backup.sh keeps it with a warning and goes
# on with the purge; the replay of rotation-check.sh gives it a verdict of
# its own instead of stopping.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
{
    days www 2026-06-01 5 00-02-02
    printf '%s\n' www-2026-02-30_00-02-02 www-2026-13-45_00-00-00
    printf '%s\n' www-2020-01-07_00-02-02
} > "$T/list"
set_archives < "$T/list"

run_backup
expect_rc 0
expect_err "WARNING: archive with an impossible date, kept: www-2026-02-30_00-02-02"
expect_err "WARNING: archive with an impossible date, kept: www-2026-13-45_00-00-00"
expect_deleted www-2020-01-07_00-02-02

run_rotation -l "$T/list"
expect_rc 0 "rotation-check.sh -l"
grep -c 'impossible date, kept$' "$T/out" > "$T/count"
[ "$(cat "$T/count")" -eq 2 ] || fail "rotation-check.sh: $(cat "$T/count") impossible dates"
expect_out "  outside the rotation   : 2"

t_done
