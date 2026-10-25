#!/bin/sh
#
# N-R3-2: the final rename put the log in place of whatever held its name:
# "-l /dev/null" left a regular file of root instead of the device. A log
# path that is a symbolic link, or exists without being a regular file, is
# now refused before anything is written. A device node needs root: with
# -r.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
snapshot snap1 "$T/root"

mkfifo "$T/fifo"
run_diff -l "$T/fifo" snap1
expect_rc 1 "FIFO"
expect_err "ERROR: log path is not a regular file: $T/fifo"
expect_calls tv 0
[ -p "$T/fifo" ] || fail "the FIFO was replaced"

printf 'target\n' > "$T/target.log"
ln -s "$T/target.log" "$T/link.log"
run_diff -l "$T/link.log" snap1
expect_rc 1 "symbolic link"
expect_err "ERROR: log path is not a regular file: $T/link.log"
[ -h "$T/link.log" ] || fail "the link was replaced"

if group root; then
    mknod -m 666 "$T/null" c 1 3
    run_diff -l "$T/null" snap1
    expect_rc 1 "device"
    expect_err "ERROR: log path is not a regular file: $T/null"
    [ -c "$T/null" ] || fail "the device was replaced"
fi

t_done
