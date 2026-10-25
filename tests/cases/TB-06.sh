#!/bin/sh
#
# TB-06: descriptor 9, which holds the lock, was inherited by every process
# of the hooks, and a daemon started there kept the lock taken. run_hook()
# closes it in the subshell of the hook, while the script itself still
# holds the lock.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
# true and not ":": a redirection that fails on a special built-in such as
# ":" ends a POSIX shell, the subshell of the hook here.
cat > "$T/hook.sh" <<HOOK
if { true >&9; } 2>/dev/null; then echo open; else echo closed; fi >> "$T/fd9"
if /usr/bin/flock -n "$T/run/tarsnap-backup.lock" true; then echo free; else echo held; fi >> "$T/fd9"
HOOK
add_hook prebackup "$T/hook.sh"
add_hook postbackup "$T/hook.sh"

run_backup
expect_rc 0
printf 'closed\nheld\nclosed\nheld\n' > "$T/fd9.expected"
expect_same "$T/fd9.expected" "$T/fd9" "descriptor 9 and lock seen by the hooks"

t_done
