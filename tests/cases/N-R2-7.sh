#!/bin/sh
#
# N-R2-7: a script overwritten in place during a run went on from the old
# offset in the new content, and ran fragments of it as root. The body now
# runs in main(), parsed whole before it starts: the run ends as the file
# read at its start says.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
# Daily archives up to yesterday: the newest one raises no warning about
# the clock, and stderr must stay empty.
{
    days www 2026-06-05 5 00-02-02
    printf '%s\n' www-2020-01-07_00-02-02 www-2020-01-08_00-02-02 \
        www-2020-01-09_00-02-02
} | set_archives

# The new content: one line more at the top, and every comment line
# removed above main(), some thousands of bytes, so that every offset
# moves.
sed -e '1a\
# A line added by an edit.' \
    -e '3,/^main() {$/{/^#/d;}' \
    "$T/sbin/tarsnap-backup.sh" > "$T/new.sh"

hold_on c
run_bg "$T/sbin/tarsnap-backup.sh"
if hold_wait c; then
    # Same inode, as nano or cp do.
    cat "$T/new.sh" > "$T/sbin/tarsnap-backup.sh"
    hold_release c
fi
bg_wait
expect_rc 0
expect_no_err
expect_deleted www-2020-01-07_00-02-02 www-2020-01-08_00-02-02 \
    www-2020-01-09_00-02-02

t_done
