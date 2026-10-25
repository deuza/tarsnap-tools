#!/bin/sh
#
# N-R2-9: under bash, a range such as [0-9] also matches digits other than
# 0 to 9 in the locale that tarsnap-backup.sh forces, so that a name
# holding fullwidth or Arabic-Indic digits took the strict form and could
# be purged. The stamp spells out [0123456789], in tarsnap-backup.sh as in
# rotation-check.sh.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
FULL=$(printf '\357\274\222')
ARAB=$(printf '\331\247')
{
    days www 2026-06-01 5 00-02-02
    printf '%s\n' "www-2020-01-07_0$FULL-02-02" "www-2020-01-0${ARAB}_00-02-02"
    printf '%s\n' www-2020-01-08_00-02-02
} > "$T/list"
set_archives < "$T/list"

run_backup --verbose
expect_rc 0 "backup"
expect_out "Outside the pattern, untouchable: www-2020-01-07_0???-02-02"
expect_out "Outside the pattern, untouchable: www-2020-01-0??_00-02-02"
expect_deleted www-2020-01-08_00-02-02

LC_ALL=en_US.UTF-8
export LC_ALL
run_rotation -l "$T/list"
unset LC_ALL
expect_rc 0 "rotation-check.sh -l"
n=$(grep -c 'outside the pattern, untouchable$' "$T/out")
[ "$n" -eq 2 ] || fail "rotation-check.sh: $n names outside the pattern, expected 2"

t_done
