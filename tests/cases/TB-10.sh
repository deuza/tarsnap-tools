#!/bin/sh
#
# TB-10: prebackup also records apt-mark showmanual, the packages installed
# on purpose; a failure of apt-mark warns with its message, and the backup
# goes on, as for apt list.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

run_backup
expect_rc 0
grep -qx base-files "$T/root/pkg-manual.txt" || fail "PKG_MANUAL not written"

# Same instant, hence the same name: the account starts empty again.
: > "$S/archives"
printf '100\n' > "$S/apt-mark.rc"
printf 'E: Could not open lock file /var/lib/dpkg/lock\n' > "$S/apt-mark.err"
run_backup
expect_rc 0 "apt-mark failing"
expect_err "WARNING: apt-mark failed, incomplete list in $T/root/pkg-manual.txt:"
expect_err "E: Could not open lock file /var/lib/dpkg/lock"
expect_calls c 1

t_done
