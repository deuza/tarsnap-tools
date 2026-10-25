#!/bin/sh
#
# TD-11: the previous log of a snapshot was emptied at startup, and lost
# when the run failed or was interrupted. It is now only replaced once the
# run has succeeded, and the working files go with a failure.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot snap1 "$T/root"
LOG="$T/log/tarsnap-diff.sh-snap1.log"
printf 'PREVIOUS\n' > "$LOG"

no_leftovers() {
    for f in "$LOG".*; do
        if [ -e "$f" ]; then
            fail "$1: working file left: $f"
        fi
    done
    [ "$(cat "$LOG")" = PREVIOUS ] || fail "$1: the previous log changed"
}

printf '1\n' > "$S/tv.rc"
run_diff snap1
expect_rc 1 "listing failing"
expect_err 'ERROR: "tarsnap -tv -f snap1" failed (exit code 1)'
no_leftovers "listing failing"
rm -f "$S/tv.rc"

signal_at tv TERM
run_diff snap1
signal_done tv
expect_rc 143 "TERM"
no_leftovers "TERM"

t_done
