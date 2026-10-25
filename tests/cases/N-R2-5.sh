#!/bin/sh
#
# N-R2-5: an exclusion made of / alone became "/*", which excludes every
# entry of BACKUP_DIRS, and --quiet hid the warning of tarsnap about the
# empty archive. check_excludes() refuses it, and removes trailing
# slashes.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

set_conf_str BACKUP_EXCLUDE "*/tmp/* / var/cache"
run_backup
expect_rc 1 "/ alone"
expect_err "ERROR: BACKUP_EXCLUDE: the pattern / would exclude everything"
expect_no_call

set_conf_str BACKUP_EXCLUDE "//"
run_backup
expect_rc 1 "//"
expect_err "ERROR: BACKUP_EXCLUDE: the pattern / would exclude everything"

set_conf_str BACKUP_EXCLUDE "$T/root/x/ */cache//"
run_backup
expect_rc 0 "trailing slashes"
expect_arg c "--exclude=$T/root/x"
expect_arg c "--exclude=$T/root/x/*"
expect_arg c "--exclude=*/cache"

t_done
