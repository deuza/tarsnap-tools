#!/bin/sh
#
# TS-01: the progress line of tarsnap-stats.sh went on drawing when the
# script died without going through its traps, kill -9 for instance. It
# now checks that the script is still there, and stops. The line only
# draws on a terminal: with -p.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init

if group pty; then
    days www 2026-06-01 3 00-02-02 | set_archives
    install_stats
    FAKE_NOW=""
    hold_on list
    run_pty "$T/tarsnap-stats.sh"
    if hold_wait list; then
        sleep 1
        kill -9 "$HELD_PID"
        hold_release list
        sleep 1
        before=$(size_of "$T/pty")
        sleep 1.5
        after=$(size_of "$T/pty")
        [ "$before" -eq "$after" ] ||
            fail "the progress line still draws after the script died"
    fi
    wait "$BG_PID" || :
fi

t_done
