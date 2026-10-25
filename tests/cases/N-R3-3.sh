#!/bin/sh
#
# N-R3-3: an entry of BACKUP_DIRS that is a symbolic link made tarsnap
# archive the link alone, without a word. Both tarsnap-backup.sh and
# tarsnap-diff.sh refuse it, through check_dirs().

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
ln -s "$T/root" "$T/link"
set_conf_str BACKUP_DIRS "$T/link"
MSG="ERROR: BACKUP_DIRS: symbolic link, give the path it points to: $T/link"

run_backup
expect_rc 1 "backup"
expect_err "$MSG"
expect_no_call

install_diff
run_diff snap1
expect_rc 1 "diff"
expect_err "$MSG"

t_done
