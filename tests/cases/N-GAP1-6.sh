#!/bin/sh
#
# N-GAP1-6: a failed run left no trace once cron had no mail transport to
# send its output. A real run now ends with a line in the system log,
# through logger, and rewrites LAST_SUCCESS when its archive exists. A dry
# run and --orphans log nothing, a failed hook is logged once, and a
# failure of logger changes nothing.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
LAST="$T/root/tarsnap-backup.last-success"

# logged LABEL TEXT: the last run called logger once, with that priority
# and text.
logged() {
    _lg_got=$(cat "$S/logger" 2>/dev/null || :)
    if [ "$_lg_got" != "-t tarsnap-backup -p $2" ]; then
        fail "$1: logger got \"$_lg_got\", expected \"-t tarsnap-backup -p $2\""
    fi
}
# last LABEL NAME: LAST_SUCCESS holds NAME.
last() {
    if [ "$(cat "$LAST" 2>/dev/null || :)" != "$2" ]; then
        fail "$1: LAST_SUCCESS does not hold $2"
    fi
}
not_logged() {
    if [ -s "$S/logger" ]; then
        fail "$1: logger was called: $(cat "$S/logger")"
    fi
}

run_backup
expect_rc 0 "success"
logged "success" "user.notice -- run succeeded, archive www-2026-06-10_12-00-00"
last "success" www-2026-06-10_12-00-00

FAKE_NOW="2026-06-10 12:01:00"
printf '2\n' > "$S/c.rc"
run_backup
expect_rc 2 "status 2"
logged "status 2" "user.warning -- run ended with exit status 2, archive www-2026-06-10_12-01-00"
last "status 2" www-2026-06-10_12-01-00

FAKE_NOW="2026-06-10 12:02:00"
printf '1\n' > "$S/c.rc"
run_backup
expect_rc 1 "failed creation"
logged "failed creation" "user.err -- run failed, exit status 1"
last "failed creation" www-2026-06-10_12-01-00
rm -f "$S/c.rc"

set_conf DAILY 0
run_backup
expect_rc 1 "retention refused"
logged "retention refused" "user.err -- run failed, exit status 1"
set_conf DAILY 90

FAKE_NOW="2026-06-10 12:03:00"
signal_at c TERM
run_backup
signal_done c
expect_rc 143 "TERM during tarsnap -c"
logged "TERM during tarsnap -c" "user.err -- run failed, exit status 143"
last "TERM during tarsnap -c" www-2026-06-10_12-01-00

FAKE_NOW="2026-06-10 12:04:00"
printf 'false\n' > "$T/hook"
add_hook prebackup "$T/hook"
run_backup
expect_rc 1 "failed prebackup"
logged "failed prebackup" "user.err -- run failed, exit status 1"
install_backup

run_backup --dry-run
expect_rc 0 "dry run"
not_logged "dry run"
run_backup --orphans
expect_rc 0 "--orphans"
not_logged "--orphans"

FAKE_NOW="2026-06-10 12:05:00"
printf '1\n' > "$S/logger.rc"
run_backup
expect_rc 0 "logger failing"
last "logger failing" www-2026-06-10_12-05-00
rm -f "$S/logger.rc"

t_done
