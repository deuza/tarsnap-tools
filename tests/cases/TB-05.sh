#!/bin/sh
#
# TB-05: -s "" ran a normal backup with its rotation, and -s --dry-run
# created a real snapshot named "-d". An empty name, and a name starting
# with "-", are now refused before anything runs.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

run_backup -s ""
expect_rc 1 '-s ""'
expect_err "ERROR: empty snapshot name"
expect_no_call

run_backup --snapshot-name=
expect_rc 1 "--snapshot-name="
expect_err "ERROR: empty snapshot name"
expect_no_call

run_backup -s --dry-run
expect_rc 1 "-s --dry-run"
expect_err "ERROR: invalid snapshot name, it must not start with -"
expect_no_call

run_backup -s "a b"
expect_rc 1 '-s "a b"'
expect_err "ERROR: invalid snapshot name, allowed characters: A-Z a-z 0-9 _ -"
expect_no_call

run_backup -s before-upgrade
expect_rc 0 "-s before-upgrade"
expect_arg c www-2026-06-10_12-00-00_before-upgrade
expect_calls list 0

t_done
