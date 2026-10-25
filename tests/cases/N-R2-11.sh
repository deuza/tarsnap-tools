#!/bin/sh
#
# N-R2-11: within a hook, set -e only stops the script on a command that
# fails on a line of its own; the comments now say so. What this relies on
# is that run_hook() calls the hook bare, never in a condition: a command
# that fails on its own line stops the run before the archive.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cat > "$T/pre.sh" <<HOOK
false
: > "$T/after"
HOOK
add_hook prebackup "$T/pre.sh"

run_backup
expect_rc 1
expect_calls c 0
if [ -e "$T/after" ]; then
    fail "the hook went on after a failing command"
fi

t_done
