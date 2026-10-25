#!/bin/sh
#
# N-GAP2-1: the totals and progress-bytes directives of tarsnap.conf wrote
# to standard error after each run, hence a cron mail every night. Without
# --verbose, every call to tarsnap now gets --no-totals and
# --no-progress-bytes along with --quiet and --no-print-stats.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
{
    days www 2026-06-01 5 00-02-02
    printf '%s\n' www-2020-01-07_00-02-02
} | set_archives

run_backup
expect_rc 0
for mode in c d; do
    for opt in --quiet --no-print-stats --no-totals --no-progress-bytes; do
        expect_arg "$mode" "$opt"
    done
done

: > "$S/archives"
run_backup --verbose
expect_arg c -v
reject_arg c --quiet

t_done
