#!/bin/sh
#
# N-R3-1: the entries of a snapshot taken when BACKUP_DIRS held more
# directories than today came out as deleted. They are now counted apart,
# with a warning and a line in the header of the log.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
mkdir "$T/other"
printf 'a\n' > "$T/other/a"
printf 'b\n' > "$T/other/b"
snapshot snap1 "$T/root" "$T/other"

run_diff snap1
expect_rc 0
expect_out "deleted     (<) : 0"
expect_err "WARNING: 3 entries of the snapshot lie outside the current BACKUP_DIRS, ignored"
grep -qF '# outside dirs: 3 entries of the snapshot outside BACKUP_DIRS' \
    "$T/log/tarsnap-diff.sh-snap1.log" || fail "no line outside dirs in the header"

t_done
