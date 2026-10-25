#!/bin/sh
#
# TD-06: the final rename was a mv -f without -T: a symbolic link to a
# directory, planted under the name of the log during the run, made mv
# move the log into that directory. mv -fT replaces the link itself.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot snap1 "$T/root"
mkdir "$T/victimdir"
LOG="$T/log/tarsnap-diff.sh-snap1.log"

hold_on tv
run_bg "$T/diff/tarsnap-diff.sh" snap1
if hold_wait tv; then
    ln -s "$T/victimdir" "$LOG"
    hold_release tv
fi
bg_wait
expect_rc 0
if [ -h "$LOG" ] || [ ! -f "$LOG" ]; then
    fail "the log is not a regular file in place of the link"
fi
grep -q '^# deleted' "$LOG" || fail "the log has no header"
if [ -n "$(ls -A "$T/victimdir")" ]; then
    fail "something was moved into the directory the link pointed to"
fi

t_done
