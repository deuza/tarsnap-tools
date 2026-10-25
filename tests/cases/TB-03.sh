#!/bin/sh
#
# TB-03: --orphans printed a delete command without any quoting, so that
# pasting it ran whatever an archive name held. The names are now read one
# per line, shown with their control characters as "?", and only those
# made of A-Z a-z 0-9 . _ - go into the command; the others are counted.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
ESC=$(printf '\033')
# Names that a shell would interpret, written literally on purpose.
# shellcheck disable=SC2016
{
    printf '%s\n' 'x;id' '$(id)' '`id`' 'has space' "esc${ESC}[31mRED"
    printf '%s\n' www-2026-01-01_00-00-00_snap web-2026-01-01_00-00-00
    printf '%s\n' www-2026-01-02_00-00-00.part www-2026-06-01_00-02-02
} | set_archives

run_backup -o
expect_rc 0
expect_calls list 1
expect_calls c 0
expect_calls d 0
expect_out 'Left out of the command: 5 name(s) holding characters'
expect_out '  esc?[31mRED'
expect_no_ctl
reject_out '  www-2026-06-01_00-02-02'
grep -F ' -d' "$T/out" > "$T/commands"
printf '  %s --keyfile %s -d -f %s -f %s\n  %s --keyfile %s -d -f %s\n' \
    "$T/bin/tarsnap" "$T/tarsnap.key" www-2026-01-01_00-00-00_snap \
    web-2026-01-01_00-00-00 "$T/bin/tarsnap" "$T/tarsnap.key" \
    www-2026-01-02_00-00-00.part > "$T/commands.expected"
expect_same "$T/commands.expected" "$T/commands" "delete commands"

t_done
