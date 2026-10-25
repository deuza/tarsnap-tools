#!/bin/sh
#
# TS-04: tarsnap-stats.sh had no passphrase method, and a protected key
# asked for its passphrase twice. -p METHOD is passed to every call as
# --passphrase METHOD, one argument whatever it holds; dev:stdin-once and
# anything that is not a method are refused, the value never repeated.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
days www 2026-06-01 3 00-02-02 | set_archives

run_stats -p env:TSPP
expect_rc 0 "env:"
for mode in verify list stats; do
    expect_arg "$mode" --passphrase
    expect_arg "$mode" env:TSPP
done

run_stats -p "file:$T/my pass"
expect_rc 0 "file: with a blank"
expect_arg list "file:$T/my pass"

run_stats -p dev:stdin-once
expect_rc 2 "dev:stdin-once"
expect_err "-p dev:stdin-once cannot work here: the key file is"
expect_no_call

run_stats -p hunter2
expect_rc 2 "not a method"
expect_err "-p: not a passphrase method (value not shown)"
reject_err hunter2
expect_no_call

t_done
