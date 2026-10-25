#!/bin/sh
#
# N-GAP1-7: the dry run advised before going into production exercises
# neither tarsnap -d nor the environment of cron. Every dry run, and the
# help, now say so.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

run_backup --dry-run
expect_rc 0
expect_out "  the right of the key to delete, the environment of cron."

run_backup -h
expect_rc 0 "-h"
expect_err "with the server, whether the key may delete, and"

t_done
