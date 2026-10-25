#!/bin/sh
#
# RC-01: rotation-check.sh let out-of-range values through, its own
# options included, and still concluded that the configuration was
# consistent. The values of the file, then those of the options, go
# through the check_retention() and check_max_purge() of the backup; the
# conclusion of a simulation rests on what each tier actually kept.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
CONF="$T/usr/local/sbin/tarsnap-backup.sh"
FAKE_NOW="2026-10-25 12:00:00"

set_conf DOW 7
run_rotation
expect_rc 1 "DOW=7 in the file"
expect_err "ERROR: DOW must be between 0 (Sunday) and 6 (Saturday)"
expect_err "ERROR: value read from $CONF"
install_backup

# refused MESSAGE OPTION...: an override refused.
refused() {
    _msg=$1
    shift
    run_rotation "$@"
    expect_rc 1 "$*"
    expect_err "ERROR: $_msg"
}
refused "DOW must be between 0 (Sunday) and 6 (Saturday)" -o 7
expect_err "ERROR: value given on the command line"
refused "DOM must be between 1 and 31" -M 0
refused "DAILY must be a decimal integer, without a leading zero" -d 030
refused "MONTHLY must be a decimal integer, without a leading zero" -m -1
refused "MAX_PURGE must be a decimal integer from 1 to 99999, without a leading zero" -b 0
refused "-D must be a decimal integer from 1 to 99999, without a leading zero" -D 0

run_rotation
expect_rc 0 "shipped values"
expect_out "All three tiers are active, the configuration is consistent."

run_rotation -m 0
expect_rc 0 "-m 0"
expect_out "WARNING: MONTHLY=0 does not extend beyond the weekly window,"
reject_out "the configuration is consistent"

run_rotation -w 0
expect_rc 0 "-w 0"
expect_out "WARNING: WEEKLY=0, the weekly tier is disabled."
reject_out "the configuration is consistent"

run_rotation -D 30
expect_rc 0 "-D 30"
expect_out "CONCLUSION: the father tier keeps nothing."
expect_out "30 simulated days do not reach its window, see -D."
reject_out "the configuration is consistent"

t_done
