#!/bin/sh
#
# N-R1-1: a name holding a newline could forge whole lines of the
# inventory, and hide a deletion or a change. Names holding a newline or a
# tab are now left out on both sides, and counted in the header of the
# log.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
TAB=$(printf '\t')
NL='
'
printf 'gone\n' > "$T/root/gone"
touch -d '2026-01-01 00:00:00 UTC' "$T/root/gone"
printf 'keep\n' > "$T/root/keep"
snapshot snap1 "$T/root"
listing_of snap1
# A name holding an escaped newline, as tarsnap lists it.
printf -- '-rw-r--r-- 1 0        0               3 2026-01-01 00:00:00 %s\n' \
    "$R/a\\nb" >> "$S/listing/snap1"

# On the system: gone is deleted, and a directory whose name holds a
# newline forges the inventory line of gone, its subdirectories spelling
# out the path.
rm "$T/root/gone"
mkdir -p "$T/root/z${NL}f${TAB}5${TAB}2026-01-01 00:00:00${TAB}$T/root/gone"
: > "$T/root/tab${TAB}name"

run_diff snap1
expect_rc 0
grep -qxF "< $R/gone" "$T/log/tarsnap-diff.sh-snap1.log" ||
    fail "the deletion of gone is hidden"
grep -qF '# skipped     : 1 in the snapshot, 2 on the system, names holding a newline or a tab' \
    "$T/log/tarsnap-diff.sh-snap1.log" || fail "no count of the names left out"
expect_err "WARNING: names holding a newline or a tab left out: 1 in the snapshot, 2 on the system"

t_done
