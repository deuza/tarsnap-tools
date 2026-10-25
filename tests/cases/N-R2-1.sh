#!/bin/sh
#
# N-R2-1: a script reinstalled with other retention values purged a whole
# tier in a single run. The purge circuit breaker stops a real run that
# would delete more than MAX_PURGE archives: nothing is deleted, the
# archive of the run and postbackup are already done, and the run fails;
# --dry-run prints the command and warns; -F lifts the limit for one run.
# rotation-check.sh reads MAX_PURGE and tells when a run now, or the first
# run after a change of values, would trip it.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
set_conf DAILY 1
set_conf WEEKLY 0
set_conf MONTHLY 0
cat > "$T/post.sh" <<HOOK
: > "$T/post.done"
HOOK
add_hook postbackup "$T/post.sh"
days www 2026-06-01 8 00-02-02 > "$T/list8"
days www 2026-06-02 7 00-02-02 > "$T/list7"

set_archives < "$T/list8"
run_backup
expect_rc 1 "8 archives"
expect_err "ERROR: 8 archives to delete, more than MAX_PURGE=7:"
expect_err "nothing was deleted"
expect_calls c 1
expect_calls d 0
[ -f "$T/post.done" ] || fail "postbackup did not run"

set_archives < "$T/list8"
run_backup --dry-run
expect_rc 0 "--dry-run"
expect_out "Dry-run, command that would be executed:"
expect_err "WARNING: 8 archives to delete, more than MAX_PURGE=7:"
expect_calls d 0

set_archives < "$T/list8"
run_backup -F --verbose
expect_rc 0 "-F"
expect_out "MAX_PURGE=7 lifted by --force-purge for this run."
expect_calls d 1
# shellcheck disable=SC2046
expect_deleted $(cat "$T/list8")

set_archives < "$T/list7"
run_backup
expect_rc 0 "7 archives"
# shellcheck disable=SC2046
expect_deleted $(cat "$T/list7")

# rotation-check.sh, on the same values.
install_rotation
run_rotation -l "$T/list8"
expect_rc 0 "rotation-check.sh, 8 archives"
expect_out "CONCLUSION: a run now would delete 8 archives, more than"
expect_out "MAX_PURGE=7: it would stop and delete nothing, unless"
run_rotation -l "$T/list7"
reject_out "CONCLUSION: a run now would delete"
run_rotation -b 10 -l "$T/list8"
reject_out "CONCLUSION: a run now would delete"

# Back to the shipped values: a change to DAILY=30 trips the breaker.
install_backup
FAKE_NOW="2026-10-25 12:00:00"
run_rotation -d 30
expect_rc 0 "rotation-check.sh -d 30"
expect_out "the first run would delete 59: it trips."
run_rotation
reject_out "the first run would delete"

t_done
