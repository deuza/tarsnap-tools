#!/bin/sh
#
# N-R1-18: a non-interactive dash keeps the default action of SIGQUIT,
# which ended tarsnap-diff.sh and tarsnap-stats.sh without their cleanup.
# QUIT now has a handler, as HUP, INT and TERM: exit status 131 after the
# cleanup, under every shell.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot snap1 "$T/root"

signal_at tv QUIT
run_diff snap1
signal_done tv
expect_rc 131 "tarsnap-diff.sh"
if [ -n "$(ls -A "$T/tmp")" ]; then
    fail "tarsnap-diff.sh left its temporary directory"
fi
for f in "$T/log/tarsnap-diff.sh-snap1.log".*; do
    if [ -e "$f" ]; then
        fail "tarsnap-diff.sh left a working file: $f"
    fi
done

days www 2026-06-01 3 00-02-02 | set_archives
install_stats
signal_at list QUIT
run_script "$T/tarsnap-stats.sh"
signal_done list
expect_rc 131 "tarsnap-stats.sh"
if [ -n "$(ls -A "$T/tmp")" ]; then
    fail "tarsnap-stats.sh left its temporary file"
fi

t_done
