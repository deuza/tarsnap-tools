#!/bin/sh
#
# The projection of rotation-check.sh against tarsnap-backup.sh replayed
# night after night, the purge done every night:
#
# - on the list of www, tests/fixtures/www-archives.txt, as tarsnap
#   --list-archives printed it on 2026-10-25: the nights where MAX_PURGE
#   stops the purge, 2026-12-04 with 10 archives and 2026-12-12 with 9,
#   and their names; the snapshot ..._MUST_DELETE, outside the pattern,
#   is never deleted;
# - in a simulation on 2026-10-25 at 12:00 in Paris: a steady state of
#   151 archives, at most 2 deletions a night, on 2026-12-22, 7 then 8
#   after 7 and 8 missed nights, and 59 at the first run with DAILY=30.
#
# A night where the breaker trips is run again one minute later with -F,
# as the README asks of the operator.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
TZ=Europe/Paris
FAKE_NOW="2026-10-25 12:00:00"
LIST="$TESTS_DIR/fixtures/www-archives.txt"
NL='
'

# Number of archives in the delete command of the last dry run.
dry_count() {
    sed -n 's/^.* -d -f //p' "$T/out" | sed "s/ -f /\\$NL/g" | grep -c .
}

# --- The list of www ---
run_rotation -l "$LIST"
expect_rc 0 "rotation-check.sh -l, list of www"
awk '/^  [0-9]+-[0-9]+-[0-9]+  [0-9]+ archives to delete, more than MAX_PURGE=/ {
         night = $1; next }
     night != "" && /^              [^ ]/ { print night " " $1; next }
     { night = "" }' "$T/out" > "$T/rotation.nights"

set_archives < "$LIST"
: > "$T/backup.nights"
: > "$T/deleted.all"
i=1
while [ "$i" -le 48 ]; do
    night=$(day_plus 2026-10-25 "$i")
    FAKE_NOW="$night 00:02:02"
    run_backup
    if [ "$RC" -ne 0 ]; then
        if grep -q 'more than MAX_PURGE=7:' "$T/err"; then
            FAKE_NOW="$night 00:03:02"
            run_backup -F
            expect_rc 0 "$night, forced"
            stub_deleted | sed "s/^/$night /" >> "$T/backup.nights"
        else
            fail "$night: exit status $RC"
        fi
    fi
    stub_deleted >> "$T/deleted.all"
    i=$((i + 1))
done
expect_same "$T/rotation.nights" "$T/backup.nights" "nights where the breaker trips, rotation-check.sh (-) and backup (+)"
for pair in 2026-12-04:10 2026-12-12:9; do
    n=$(grep -c "^${pair%:*} " "$T/backup.nights")
    [ "$n" -eq "${pair#*:}" ] || fail "${pair%:*}: $n archives, expected ${pair#*:}"
done
n=$(cut -d' ' -f1 "$T/backup.nights" | LC_ALL=C sort -u | wc -l)
[ "$n" -eq 2 ] || fail "$n nights where the breaker trips, expected 2"
if grep -q MUST_DELETE "$T/deleted.all"; then
    fail "the snapshot outside the pattern was deleted"
fi
grep -q MUST_DELETE "$S/archives" || fail "the snapshot outside the pattern is gone"

# --- Simulation ---
FAKE_NOW="2026-10-25 12:00:00"
run_rotation
expect_rc 0 "simulation"
expect_out "  kept in total          : 151"
expect_out "  a normal night deletes at most 2, over 62 nights."
expect_out "  it trips after 8 missed night(s) in a row, or with a"
expect_out "  clock 8 day(s) ahead, deleting 8 (7 a day less)."
run_rotation -d 30
expect_out "  the first run would delete 59: it trips."

# The steady state: five years, then a run that purges them.
days www "$(day_plus 2026-10-25 -1825)" 1825 12-00-00 | set_archives
run_backup -F
expect_rc 0 "steady state"
n=$(wc -l < "$S/archives")
[ "$n" -eq 151 ] || fail "steady state of $n archives, expected 151"
cp "$S/archives" "$T/steady"

: > "$T/counts"
i=1
while [ "$i" -le 62 ]; do
    night=$(day_plus 2026-10-25 "$i")
    FAKE_NOW="$night 12:00:00"
    run_backup
    expect_rc 0 "$night"
    printf '%s %s\n' "$night" "$(stub_deleted | grep -c .)" >> "$T/counts"
    i=$((i + 1))
done
max=$(awk '$2 > m { m = $2 } END { print m + 0 }' "$T/counts")
[ "$max" -eq 2 ] || fail "at most $max deletions a night, expected 2"
nights=$(awk -v m="$max" '$2 == m { printf "%s ", $1 }' "$T/counts")
[ "$nights" = "2026-12-22 " ] || fail "nights with $max deletions: $nights"

for pair in 7:2026-11-02 8:2026-11-03; do
    set_archives < "$T/steady"
    FAKE_NOW="${pair#*:} 12:00:00"
    run_backup --dry-run
    n=$(dry_count)
    [ "$n" -eq "${pair%:*}" ] ||
        fail "after ${pair%:*} missed nights: $n deletions, expected ${pair%:*}"
done
expect_err "WARNING: 8 archives to delete, more than MAX_PURGE=7:"

set_archives < "$T/steady"
set_conf DAILY 30
FAKE_NOW="2026-10-25 12:00:00"
run_backup --dry-run
n=$(dry_count)
[ "$n" -eq 59 ] || fail "first run with DAILY=30: $n deletions, expected 59"

t_done
