#!/bin/sh
#
# N-R1-5: the lock was created in mode 0644, and flock(2) also locks a
# descriptor opened read-only: any local user could hold it and block the
# backups. It is created in 0600, a lock left in 0644 by an earlier
# version is brought back to 0600 once held, and a lock held elsewhere
# stops the run before anything else.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
LOCK="$T/run/tarsnap-backup.lock"

run_backup
expect_rc 0
expect_mode "$LOCK" -rw-------

rm -f "$LOCK"
(umask 022; : > "$LOCK")
expect_mode "$LOCK" -rw-r--r--
: > "$S/archives"
run_backup
expect_rc 0 "lock left in 0644"
expect_mode "$LOCK" -rw-------

# Held by another process until a line arrives on the FIFO, whose path
# the inner shell receives as $1.
mkfifo "$T/release"
# shellcheck disable=SC2016
/usr/bin/flock "$LOCK" /bin/sh -c 'read -r x < "$1"' sh "$T/release" &
holder=$!
i=0
while /usr/bin/flock -n "$LOCK" true && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
: > "$S/archives"
run_backup
expect_rc 1 "lock held"
expect_err "ERROR: another instance is already running (lock $LOCK)"
expect_no_call
printf 'go\n' > "$T/release"
wait "$holder"

# Another user cannot even open it: needs root, to become nobody.
if is_root; then
    chmod 711 "$T"
    chmod 755 "$T/run"
    if setpriv --reuid=65534 --regid=65534 --clear-groups \
        /usr/bin/flock -n "$LOCK" true 2> "$T/err"; then
        fail "nobody could take the lock"
    fi
    expect_err "Permission denied"
    chmod 700 "$T"
fi

t_done
