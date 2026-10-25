#!/bin/sh
#
# TD-08: a relative or non-canonical -l escaped the warning about a log
# placed under BACKUP_DIRS, where it shows up in its own diff. The
# directory of the log is now resolved first.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
mkdir "$T/root/sub"
snapshot snap1 "$T/root"
TC=$(cd -P "$T" && pwd -P)

# Relative to $T, where the runs start.
run_diff -l root/sub/my.log snap1
expect_rc 0 "relative -l"
expect_err "WARNING: the log $TC/root/sub/my.log is under $T/root, covered by BACKUP_DIRS."

ln -s "$T/root" "$T/lnk"
run_diff -l "$T/lnk/other.log" snap1
expect_rc 0 "-l through a link"
expect_err "WARNING: the log $TC/root/other.log is under $T/root, covered by BACKUP_DIRS."

t_done
