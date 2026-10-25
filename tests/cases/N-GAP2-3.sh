#!/bin/sh
#
# N-GAP2-3: the temporary directory of tarsnap-diff.sh, and the working
# file of its log, showed up in the diff when they lay under BACKUP_DIRS.
# The walk leaves them out.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
mkdir "$T/root/tmpwork"
snapshot snap1 "$T/root"

TMPDIR="$T/root/tmpwork"
run_diff -l "$T/root/d.log" snap1
TMPDIR="$T/tmp"
expect_rc 0
expect_err "WARNING: the log $T/root/d.log is under $T/root, covered by BACKUP_DIRS."
expect_out "new         (>) : 0"

t_done
