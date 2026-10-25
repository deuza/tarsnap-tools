#!/bin/sh
#
# TD-09: a snapshot name outside A-Z a-z 0-9 _ - . was refused, though
# tarsnap accepts it. With -l, the name only reaches tarsnap and the
# screen, and any name is accepted, except a "/" or a control character.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot 'snap:2026+x@y' "$T/root"
ESC=$(printf '\033')

run_diff 'snap:2026+x@y'
expect_rc 1 "without -l"
expect_err "ERROR: invalid snapshot name, allowed characters: A-Z a-z 0-9 _ - . (any other name needs -l)"

run_diff -l "$T/log/other.log" 'snap:2026+x@y'
expect_rc 0 "with -l"

run_diff -l "$T/log/other.log" 'a/b'
expect_rc 1 "a /"
expect_err "ERROR: invalid snapshot name: no / and no control character"

run_diff -l "$T/log/other.log" "a${ESC}b"
expect_rc 1 "ESC"
expect_err "ERROR: invalid snapshot name: no / and no control character"

t_done
