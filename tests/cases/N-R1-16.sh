#!/bin/sh
#
# N-R1-16: the log was created safely, then reopened by its path, so that
# a name replaced during the run made root write into another file. The
# working file of the log is opened once, on descriptors 3 and 4, and
# never reopened by its path.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot snap1 "$T/root"
printf 'ORIGINAL\n' > "$T/victim"

hold_on tv
run_bg "$T/diff/tarsnap-diff.sh" snap1
if hold_wait tv; then
    for work in "$T/log/tarsnap-diff.sh-snap1.log".*; do
        rm -f "$work"
        ln -s "$T/victim" "$work"
    done
    hold_release tv
fi
bg_wait
expect_rc 0
[ "$(cat "$T/victim")" = ORIGINAL ] || fail "the file behind the link was written"
grep -q '^# deleted' "$T/log/tarsnap-diff.sh-snap1.log" ||
    fail "the log has no header"

t_done
