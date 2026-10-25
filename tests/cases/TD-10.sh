#!/bin/sh
#
# TD-10: the progress line of tarsnap-diff.sh went on drawing when the
# script died without going through its traps, kill -9 for instance. It
# now checks that the script is still there, and stops. The line only
# draws on a terminal: with -p.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init

if group pty; then
    install_backup
    install_diff
    snapshot snap1 "$T/root"
    FAKE_NOW=""
    hold_on tv
    run_pty "$T/diff/tarsnap-diff.sh" snap1
    if hold_wait tv; then
        sleep 1
        kill -9 "$HELD_PID"
        hold_release tv
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
