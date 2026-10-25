#!/bin/sh
#
# TB-01: retention values not validated, so that a typo purged in silence.
# check_retention() refuses a value that is not a decimal integer written
# without a leading zero, of five digits at most, DAILY below 1, DOW past
# 6 and DOM outside 1 to 31: before prebackup, before any call to tarsnap,
# and without echoing the value. WEEKLY or MONTHLY at 0 still disables its
# tier.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cp "$T/sbin/tarsnap-backup.sh" "$T/sbin/orig.sh"
CR=$(printf '\r')

# refused NAME VALUE MESSAGE
refused() {
    cp "$T/sbin/orig.sh" "$T/sbin/tarsnap-backup.sh"
    set_conf "$1" "$2"
    rm -f "$T/root/pkg-selections.txt"
    run_backup
    expect_rc 1 "$1=$2"
    expect_err "ERROR: $3"
    expect_no_call
    if [ -e "$T/root/pkg-selections.txt" ]; then
        fail "$1=$2: prebackup ran"
    fi
}

refused DOW 7 "DOW must be between 0 (Sunday) and 6 (Saturday)"
refused DOW Mon "DOW must be a decimal integer, without a leading zero"
reject_err "Mon"
refused DOW "1#Monday" "DOW must be a decimal integer, without a leading zero"
refused DOW "1$CR" "DOW must be a decimal integer, without a leading zero"
refused DOM 0 "DOM must be between 1 and 31"
refused DOM 32 "DOM must be between 1 and 31"
refused DAILY 0 "DAILY must be at least 1"
refused DAILY 030 "DAILY must be a decimal integer, without a leading zero"
refused DAILY 090 "DAILY must be a decimal integer, without a leading zero"
refused DAILY -1 "DAILY must be a decimal integer, without a leading zero"
refused WEEKLY 123456 "WEEKLY must have at most 5 digits"
refused MONTHLY "" "MONTHLY must be a decimal integer, without a leading zero"

# The limits that remain allowed.
cp "$T/sbin/orig.sh" "$T/sbin/tarsnap-backup.sh"
set_conf WEEKLY 0
set_conf MONTHLY 0
set_conf DOW 0
set_conf DOM 31
set_conf DAILY 99999
run_backup
expect_rc 0 "WEEKLY=0 MONTHLY=0 DOW=0 DOM=31 DAILY=99999"
expect_calls c 1

t_done
