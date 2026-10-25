#!/bin/sh
#
# N-R1-11: the archive list was split on blanks, so that a name holding a
# space gave words of which one could take the strict form, and tarsnap -d
# received a -f for an archive that does not exist. Each line is now one
# name, blanks at either end included, in tarsnap-backup.sh as in the
# replay of rotation-check.sh.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
{
    printf '%s\n' 'pre upgrade www-2025-06-03_03-00-00'
    printf '%s\n' ' www-2026-06-01_00-02-02' 'www-2026-06-02_00-02-02 '
    days www 2026-06-03 5 00-02-02
    printf '%s\n' www-2020-01-07_00-02-02
} > "$T/list"
set_archives < "$T/list"

run_backup --verbose
expect_rc 0 "backup"
expect_out "Outside the pattern, untouchable: pre upgrade www-2025-06-03_03-00-00"
expect_out "Outside the pattern, untouchable:  www-2026-06-01_00-02-02"
expect_out "Outside the pattern, untouchable: www-2026-06-02_00-02-02 "
expect_deleted www-2020-01-07_00-02-02

run_rotation -l "$T/list"
expect_rc 0 "rotation-check.sh -l"
n=$(grep -c 'outside the pattern, untouchable$' "$T/out")
[ "$n" -eq 3 ] || fail "rotation-check.sh: $n names outside the pattern, expected 3"

t_done
