#!/bin/sh
#
# N-R1-9, with TD-15: tarsnap -x reads each line of -T as a pattern, so
# that a name holding "[", "*", "?" or a backslash extracted other files,
# or none. The list given to -T is now an escaped copy.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
mkdir "$T/root/up"
for f in '[id].vue' i.vue d.vue 'up/*' up/a; do
    printf 'same\n' > "$T/root/$f"
done
snapshot snap1 "$T/root"
touch -d '2026-01-02 00:00:00' "$T/root/[id].vue" "$T/root/up/*"

run_diff snap1
expect_rc 0
expect_calls x 1
n=$(awk '$2 == "x" { print $1 }' "$S/calls")
grep -qxF "$R/\\[id\\].vue" "$S/call.$n.T" || fail "-T lacks the escaped [id].vue"
grep -qxF "$R/up/\\*" "$S/call.$n.T" || fail "-T lacks the escaped up/*"
printf '%s\n' "$R/[id].vue" "$R/up/*" | LC_ALL=C sort > "$T/x.expected"
LC_ALL=C sort "$S/call.$n.x" > "$T/x.actual"
expect_same "$T/x.expected" "$T/x.actual" "files extracted"
LOG="$T/log/tarsnap-diff.sh-snap1.log"
grep -qxF "= $R/[id].vue" "$LOG" || fail "[id].vue is not identical"
grep -qxF "= $R/up/*" "$LOG" || fail "up/* is not identical"

t_done
