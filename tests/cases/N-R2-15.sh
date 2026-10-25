#!/bin/sh
#
# N-R2-15: of a path present twice in the archive, sort -u kept the first
# occurrence, while tarsnap -x restores the last one. The last one is now
# kept.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
printf 'twelve bytes' > "$T/root/app.log"
touch -d '2026-01-02 00:00:00 UTC' "$T/root/app.log"
snapshot snap1 "$T/root"
listing_of snap1
# An older occurrence of app.log, listed before the one of the store.
{
    sed -n 1p "$S/listing/snap1"
    printf -- '-rw-r--r-- 1 0        0               6 2026-01-01 00:00:00 %s\n' \
        "$R/app.log"
    sed 1d "$S/listing/snap1"
} > "$S/listing.tmp"
mv "$S/listing.tmp" "$S/listing/snap1"

run_diff snap1
expect_rc 0
expect_calls x 0
grep -qxF "= $R/app.log" "$T/log/tarsnap-diff.sh-snap1.log" ||
    fail "app.log is not judged on its last occurrence"

t_done
