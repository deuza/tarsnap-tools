#!/bin/sh
#
# N-R2-4: archive names went raw to the terminal and to the cron mail, so
# that ESC or CR in a name could drive the terminal of root. Every byte
# outside printable ASCII is shown as "?": --orphans and the rotation of
# tarsnap-backup.sh, the replay of rotation-check.sh, and the progress line
# of tarsnap-stats.sh, checked with -p since it only draws on a terminal.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
ESC=$(printf '\033')
CR=$(printf '\r')
{
    printf '%s\n' "other${ESC}[31mRED${ESC}[0m" "x${CR}Y.part"
    days www 2026-06-01 5 00-02-02
    printf '%s\n' www-2020-01-07_00-02-02
} > "$T/list"

set_archives < "$T/list"
run_backup -o
expect_rc 0 "--orphans"
expect_out "  other?[31mRED?[0m"
expect_out "  x?Y.part"
expect_no_ctl

set_archives < "$T/list"
run_backup --verbose
expect_rc 0 "rotation"
expect_out "Outside the pattern, untouchable: other?[31mRED?[0m"
expect_err "WARNING: partial archive: x?Y.part"
expect_no_ctl

run_rotation -l "$T/list"
expect_rc 0 "rotation-check.sh -l"
expect_out "  other?[31mRED?[0m"
expect_out "  x?Y.part"
expect_no_ctl

if group pty; then
    printf 'www-2026-06-01_00-02-02\nlast%s[31mRED\n' "$ESC" | set_archives
    cp "$REPO_DIR/tarsnap-stats.sh" "$T/tarsnap-stats.sh"
    TARSNAP="$T/bin/tarsnap"
    export TARSNAP
    hold_on list
    FAKE_NOW=""
    run_pty "$T/tarsnap-stats.sh"
    if hold_wait list; then
        sleep 1
        hold_release list
    fi
    wait "$BG_PID" || :
    grep -qF 'last: last?[31mRED' "$T/pty" ||
        fail "tarsnap-stats.sh: the name is not shown with ?"
    if grep -qF "last${ESC}[31m" "$T/pty"; then
        fail "tarsnap-stats.sh: raw ESC on the terminal"
    fi
fi

t_done
