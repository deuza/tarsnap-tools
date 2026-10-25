#!/bin/sh
#
# N-R1-7: read_value() kept the leading digits of a value, so that
# DOW=1#Monday announced kept the archives that the backup deletes. The
# word is now read whole and goes through check_retention(); a quoted
# value and a second assignment are refused, the shell keeping the last
# one where the tool read the first.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
cp "$T/sbin/tarsnap-backup.sh" "$T/sbin/orig.sh"
CONF="$T/usr/local/sbin/tarsnap-backup.sh"
CR=$(printf '\r')

refused() {
    run_rotation
    expect_rc 1 "$1"
    expect_err "ERROR: $2"
    cp "$T/sbin/orig.sh" "$T/sbin/tarsnap-backup.sh"
    sync_backup
}

set_conf DOW "1#Monday"
refused "DOW=1#Monday" "DOW must be a decimal integer, without a leading zero"
set_conf DOW "1$CR"
refused "DOW=1 CR" "DOW must be a decimal integer, without a leading zero"
set_conf DOW '"1"'
refused 'DOW="1"' "DOW is quoted in $CONF, write it without quotes"
printf 'DOW=2\n' >> "$T/sbin/tarsnap-backup.sh"
sync_backup
refused "DOW twice" "DOW is assigned on more than one line in $CONF"

run_rotation
expect_rc 0 "shipped values"
expect_out "weekly     WEEKLY=12  DOW=1"

t_done
