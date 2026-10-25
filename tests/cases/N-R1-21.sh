#!/bin/sh
#
# N-R1-21, with RC-05: when the installed tarsnap-backup.sh could not be
# read, the companion tools fell back silently on the copy of the
# repository, whose values production often does not use. Both now stop
# when the installed copy exists but cannot be read. Root reads anything:
# under root, the tools run as nobody.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
install_diff
CONF="$T/usr/local/sbin/tarsnap-backup.sh"
MSG="ERROR: $CONF exists but is not readable, run as root or use -f"
FAKE_NOW=""

# run_as SCRIPT ARGS: as this user, or as nobody under root.
run_as() {
    stub_reset
    RC=0
    if is_root; then
        # shellcheck disable=SC2086
        (cd "$T" && TMPDIR="$T/tmp" exec setpriv --reuid=65534 --regid=65534 \
            --clear-groups $TEST_SHELL "$@") \
            < /dev/null > "$T/out" 2> "$T/err" || RC=$?
    else
        # shellcheck disable=SC2086
        (cd "$T" && exec $TEST_SHELL "$@") \
            < /dev/null > "$T/out" 2> "$T/err" || RC=$?
    fi
}

if is_root; then
    chmod 711 "$T"
    chmod 755 "$T/rc" "$T/diff" "$T/usr" "$T/usr/local" "$T/usr/local/sbin" \
        "$T/sbin" "$T/bin" "$T/stub"
    chmod 1777 "$T/tmp"
    chmod 644 "$T/rc/rotation-check.sh" "$T/diff/tarsnap-diff.sh" \
        "$T/sbin/tarsnap-backup.sh"
fi
chmod 000 "$CONF"

run_as "$T/rc/rotation-check.sh"
expect_rc 1 "rotation-check.sh"
expect_err "$MSG"

run_as "$T/diff/tarsnap-diff.sh" snap1
expect_rc 1 "tarsnap-diff.sh"
expect_err "$MSG"

run_as "$T/rc/rotation-check.sh" -f "$T/sbin/tarsnap-backup.sh"
expect_rc 0 "rotation-check.sh -f"
expect_out "configuration read from $T/sbin/tarsnap-backup.sh"

chmod 700 "$T"

t_done
