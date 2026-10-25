#!/bin/sh
#
# TB-11: a passphrase file that gives tarsnap an empty passphrase was
# accepted, and tarsnap failed on it after prebackup. Both scripts refuse,
# before anything runs, a file that is unreadable, empty, of more than one
# line, or whose line is empty or starts with a CR.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
key_protected "$T/tarsnap.key"
set_conf_str TARSNAP_PASSPHRASE "file:$T/pp"
install_diff
snapshot snap1 "$T/root"
MSG="passphrase-protected key, passphrase file $T/pp unreadable, empty or not a single line: $T/tarsnap.key"

# refused LABEL: the content of $T/pp is ready.
refused() {
    run_backup
    expect_rc 1 "backup, $1"
    expect_err "ERROR: $MSG"
    expect_no_call
    run_diff snap1
    expect_rc 1 "diff, $1"
    expect_err "ERROR: $MSG"
}

: > "$T/pp"
refused "empty file"
printf '\n' > "$T/pp"
refused "empty line"
printf '\r\n' > "$T/pp"
refused "CR LF"
printf '\rsecret\n' > "$T/pp"
refused "line starting with a CR"
printf 'secret\nsecond\n' > "$T/pp"
refused "two lines"
rm -f "$T/pp"
refused "missing file"

printf 'secret\n' > "$T/pp"
run_backup
expect_rc 0 "backup, valid file"
run_diff snap1
expect_rc 0 "diff, valid file"

t_done
