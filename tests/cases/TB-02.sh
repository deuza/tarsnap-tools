#!/bin/sh
#
# TB-02, with TB-12: postbackup and the rotation were skipped whenever
# tarsnap -c failed, even with exit status 2, an archive created with some
# files unread. postbackup now runs in every case and receives that status;
# 2 gives a warning, a rotation only if the archive of the run is listed,
# and a run that exits with 2; any other failure stops before the rotation.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cat > "$T/post.sh" <<HOOK
printf '%s\n' "\$1" > "$T/post.rc"
HOOK
add_hook postbackup "$T/post.sh"

reset() {
    {
        days www 2026-06-01 5 00-02-02
        printf 'www-2020-01-07_00-02-02\n'
    } | set_archives
    rm -f "$S/c.rc" "$S/c.noadd" "$T/post.rc"
}

post_rc() {
    if [ ! -f "$T/post.rc" ]; then
        fail "$1: postbackup did not run"
    elif [ "$(cat "$T/post.rc")" != "$2" ]; then
        fail "$1: postbackup received $(cat "$T/post.rc"), expected $2"
    fi
}

# Status 2, the archive written: warning, purge, exit status 2.
reset
printf '2\n' > "$S/c.rc"
run_backup
expect_rc 2 "status 2"
expect_err "WARNING: tarsnap -c exited with status 2: some files"
post_rc "status 2" 2
expect_deleted www-2020-01-07_00-02-02

# Status 2, the archive missing from the list: no rotation.
reset
printf '2\n' > "$S/c.rc"
: > "$S/c.noadd"
run_backup
expect_rc 1 "status 2, archive not listed"
expect_err "ERROR: archive www-2026-06-10_12-00-00 not listed after an exit status 2, no rotation"
post_rc "status 2, archive not listed" 2
expect_calls d 0

# Status 1: postbackup, then a stop before the listing.
reset
printf '1\n' > "$S/c.rc"
run_backup
expect_rc 1 "status 1"
expect_err "ERROR: tarsnap -c failed (exit status 1), no rotation"
post_rc "status 1" 1
expect_calls list 0
expect_calls d 0

# A snapshot with status 2: postbackup, exit status 2, no rotation.
reset
printf '2\n' > "$S/c.rc"
run_backup -s before-upgrade
expect_rc 2 "snapshot, status 2"
post_rc "snapshot, status 2" 2
expect_calls list 0
expect_calls d 0

t_done
