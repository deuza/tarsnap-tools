#!/bin/sh
#
# TB-11: a passphrase file that gives tarsnap an empty passphrase was
# accepted, and tarsnap failed on it after prebackup. Both scripts refuse,
# before anything runs, a file that is unreadable, a directory, empty, of
# more than one line, of 2048 bytes or more, or whose line is empty or
# starts with a CR or a NUL. A passphrase whose bytes are not UTF-8 is
# accepted, whatever the locale of the caller.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
key_protected "$T/tarsnap.key"
set_conf_str TARSNAP_PASSPHRASE "file:$T/pp"
install_diff
snapshot snap1 "$T/root"
MSG="passphrase-protected key, passphrase file $T/pp unreadable, a directory, empty, too long or not a single line: $T/tarsnap.key"

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
mkdir "$T/pp"
refused "directory"
rmdir "$T/pp"
printf '%2047s\n' '' | tr ' ' a > "$T/pp"
refused "2048 bytes, LF included"
printf '%2048s' '' | tr ' ' a > "$T/pp"
refused "2048 bytes, no LF"
printf '\000secret\n' > "$T/pp"
refused "line starting with a NUL"

printf 'secret\n' > "$T/pp"
run_backup
expect_rc 0 "backup, valid file"
run_diff snap1
expect_rc 0 "diff, valid file"

# accepted LABEL TIME: the content of $T/pp is ready. Each run creates its
# archive, hence a time of its own, the stub refusing a name already taken.
accepted() {
    FAKE_NOW="2026-06-10 $2"
    run_backup
    expect_rc 0 "backup, $1"
    reject_err "$MSG"
    run_diff snap1
    expect_rc 0 "diff, $1"
    reject_err "$MSG"
}

printf '%2046s\n' '' | tr ' ' a > "$T/pp"
accepted "2047 bytes, LF included" 12:01:00
printf '%2047s' '' | tr ' ' a > "$T/pp"
accepted "2047 bytes, no LF" 12:02:00
printf 'caf\351\n' > "$T/pp"
LANG=en_US.UTF-8
accepted "Latin-1 byte, caller in a UTF-8 locale" 12:03:00
LANG=C

t_done
