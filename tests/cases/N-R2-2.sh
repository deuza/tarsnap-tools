#!/bin/sh
#
# N-R2-2: an error of apt list was thrown away, and set -e stopped the
# backup every night without a word. The failure now shows apt's own
# message with a warning, and the backup goes on.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
printf '100\n' > "$S/apt.rc"
printf '%s\n' "E: Conflicting values set for option Signed-By" \
    "E: The list of sources could not be read." > "$S/apt.err"

run_backup
expect_rc 0
expect_err "WARNING: apt list failed, incomplete list in $T/root/pkg-list.txt:"
expect_err "E: The list of sources could not be read."
expect_calls c 1

t_done
