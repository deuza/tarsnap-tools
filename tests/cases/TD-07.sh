#!/bin/sh
#
# TD-07: -e "" was ignored, so that a snapshot taken without exclusions
# could not be replayed without them. -e "" now replaces BACKUP_EXCLUDE
# with nothing.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
R=${T#/}/root
printf 'tmp\n' > "$T/root/a.tmp"
printf 'keep\n' > "$T/root/keep.txt"
set_conf_str BACKUP_EXCLUDE "*.tmp"
install_diff
snapshot snap1 "$T/root"
LOG="$T/log/tarsnap-diff.sh-snap1.log"

run_diff -i snap1
expect_rc 0 "BACKUP_EXCLUDE"
if grep -qF "$R/a.tmp" "$LOG"; then
    fail "a.tmp is compared despite BACKUP_EXCLUDE"
fi

run_diff -i -e "" snap1
expect_rc 0 '-e ""'
grep -qxF "= $R/a.tmp" "$LOG" || fail '-e "" did not bring a.tmp back'
grep -qx '# exclusions  : ' "$LOG" || fail "the header still shows exclusions"

t_done
