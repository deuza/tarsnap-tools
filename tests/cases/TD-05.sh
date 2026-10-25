#!/bin/sh
#
# TD-05: tarsnap -tv escapes the names, find writes them raw, and a name
# holding a backslash or a byte that is not printable came out both
# deleted and new. The escapes of tarsnap are now decoded once: \\, the
# letters of the control characters, and \ooo for the other bytes.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
CTL=$(printf '\001')
BAD=$(printf '\377')
BS=$(printf '\134')
for name in "back${BS}slash" "ctl${CTL}x" "bad${BAD}x"; do
    printf 'abc\n' > "$T/root/$name"
    touch -d '2026-01-01 00:00:00 UTC' "$T/root/$name"
done
snapshot snap1 "$T/root"
# The listing as tarsnap writes it in en_US.UTF-8.
{
    printf 'drwxr-xr-x 2 0        0            4096 2026-01-01 00:00:00 %s/\n' "$R"
    for name in 'back\\slash' 'ctl\001x' 'bad\377x'; do
        printf -- '-rw-r--r-- 1 0        0               4 2026-01-01 00:00:00 %s\n' \
            "$R/$name"
    done
} > "$S/listing/snap1"
touch -d '2026-01-01 00:00:00 UTC' "$T/root"

run_diff snap1
expect_rc 0
expect_out "deleted     (<) : 0"
expect_out "new         (>) : 0"
expect_out "identical   (=) : 4"

t_done
