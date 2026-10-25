#!/bin/sh
#
# N-R1-12: the archive of a run could be deleted by that very run: its
# name is fixed before the creation, the age is measured after it, and a
# creation that crosses midnight made it older than DAILY days. It is now
# kept whatever the clock says.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
# The daily tier alone: no week or month to keep an archive for.
set_conf DAILY 1
set_conf WEEKLY 0
set_conf MONTHLY 0
FAKE_NOW="2026-06-10 23:50:00"
printf 'www-2026-06-08_23-50-00\n' | set_archives

# The creation starts at 23:50 and ends at 00:40, the next day.
hold_on c
run_bg "$T/sbin/tarsnap-backup.sh" --verbose
if hold_wait c; then
    set_now "2026-06-11 00:40:00"
    hold_release c
fi
bg_wait
expect_rc 0
expect_out "Archive just created, kept: www-2026-06-10_23-50-00"
expect_deleted www-2026-06-08_23-50-00

t_done
