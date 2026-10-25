#!/bin/sh
#
# N-GAP1-1: a key shared by two machines makes the one that did not write
# last fail on every run, which a dry run cannot see. Every dry run, and
# the help, now say that the cache directory is not checked against the
# server; the orphans are described as left by a machine that used the
# key before.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

run_backup --dry-run
expect_rc 0
expect_out "Dry-run, not checked: the cache directory against the server,"

run_backup -h
expect_rc 0 "-h"
expect_err "checked: whether the cache directory is in sync"

t_done
