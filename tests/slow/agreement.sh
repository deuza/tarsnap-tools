#!/bin/sh
#
# rotation-check.sh -l against a --dry-run --verbose of tarsnap-backup.sh,
# on the same list, at the same frozen instant: every name must get the
# same verdict from both, son, father, grandfather, purge, outside the
# pattern, partial or impossible date.
#
# The list holds five years of nightly archives, with missed nights (a
# Monday, a first of the month, eight nights in a row) and names at the
# edges: an impossible date, blanks, an ESC, a .part, another host, a
# fullwidth digit, a snapshot. The instants: 2026-04-15 00:02 in Paris,
# the day without midnight of 2026-03-08 in Havana, both nights of the
# change of time in Paris, and the turn of a month.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
ESC=$(printf '\033')
TAB=$(printf '\t')
FULL=$(printf '\357\274\223')

# verdicts_backup: "class<TAB>name" for each archive, from the output of
# the dry run.
verdicts_backup() {
    {
        sed -n -e "s/^Daily .*, kept: \\(.*\\)\$/son$TAB\\1/p" \
            -e "s/^Weekly .*, kept: \\(.*\\)\$/father$TAB\\1/p" \
            -e "s/^Monthly .*, kept: \\(.*\\)\$/grandfather$TAB\\1/p" \
            -e "s/^Outside the pattern, untouchable: \\(.*\\)\$/outside$TAB\\1/p" \
            "$T/out"
        sed -n -e "s/^WARNING: partial archive: \\(.*\\)\$/partial$TAB\\1/p" \
            -e "s/^WARNING: archive with an impossible date, kept: \\(.*\\)\$/impossible$TAB\\1/p" \
            "$T/err"
        # The purge: the names after " -d " in the command of the dry run,
        # none of which holds a blank.
        sed -n 's/^.* -d -f //p' "$T/out" | sed "s/ -f /\\
/g" | sed "s/^/purge$TAB/"
    } | sed 's/ *$//' | LC_ALL=C sort
}

# verdicts_rotation: the same, from the replay.
verdicts_rotation() {
    sed -n -e "s/^  \\(.*\\) KEPT  (son, daily)\$/son$TAB\\1/p" \
        -e "s/^  \\(.*\\) KEPT  (father, weekly)\$/father$TAB\\1/p" \
        -e "s/^  \\(.*\\) KEPT  (grandfather, monthly)\$/grandfather$TAB\\1/p" \
        -e "s/^  \\(.*\\) DELETED\$/purge$TAB\\1/p" \
        -e "s/^  \\(.*\\) PARTIAL, left in place\$/partial$TAB\\1/p" \
        -e "s/^  \\(.*\\) outside the pattern, untouchable\$/outside$TAB\\1/p" \
        -e "s/^  \\(.*\\) impossible date, kept\$/impossible$TAB\\1/p" \
        "$T/out" | sed 's/ *$//' | LC_ALL=C sort
}

for instant in "Europe/Paris|2026-04-15 00:02:00" \
    "America/Havana|2026-03-08 01:30:00" \
    "Europe/Paris|2026-03-29 00:02:00" \
    "Europe/Paris|2026-10-25 00:02:00" \
    "Europe/Paris|2026-08-31 00:02:00" \
    "Europe/Paris|2026-09-01 00:02:00"; do
    TZ=${instant%%|*}
    FAKE_NOW=${instant#*|}
    day=${FAKE_NOW%% *}
    hms=$(printf '%s\n' "${FAKE_NOW#* }" | tr : -)
    # Five years up to the night before, missed nights taken out.
    days www "$(day_plus "$day" -1826)" 1826 "$hms" |
        grep -v -e "^www-$(day_plus "$day" -200)_" \
            -e "^www-$(day_plus "$day" -400)_" > "$T/list"
    monday=$(date -d "$(day_plus "$day" -150) 12:00" '+%u')
    gap=$(day_plus "$day" "$((-150 - monday + 1))")
    first=$(date -d "$(day_plus "$day" -300) 12:00" '+%Y-%m-01')
    grep -v -e "^www-${gap}_" -e "^www-${first}_" "$T/list" > "$T/list.tmp"
    i=10
    while [ "$i" -lt 18 ]; do
        printf '^www-%s_\n' "$(day_plus "$day" "-$i")"
        i=$((i + 1))
    done > "$T/gaps"
    grep -v -f "$T/gaps" "$T/list.tmp" > "$T/list"
    {
        printf '%s\n' www-2026-02-30_00-02-00 'pre upgrade www-2025-06-03_03-00-00'
        printf '%s\n' " www-2026-01-05_00-02-00" "other${ESC}[31mRED"
        printf '%s\n' www-2026-01-02_00-02-00.part web-2026-01-01_00-02-00
        printf '%s\n' "www-2026-01-0${FULL}_00-02-00" www-2026-09-14_03-32-44_MUST_DELETE
    } >> "$T/list"
    case "$TZ" in
        America/Havana) printf 'www-2026-03-08_01-00-00\n' >> "$T/list" ;;
    esac
    n=$(wc -l < "$T/list")

    set_archives < "$T/list"
    run_backup --dry-run --verbose
    expect_rc 0 "$TZ $FAKE_NOW: backup"
    verdicts_backup > "$T/backup.v"
    run_rotation -l "$T/list"
    expect_rc 0 "$TZ $FAKE_NOW: rotation-check.sh"
    verdicts_rotation > "$T/rotation.v"
    expect_same "$T/backup.v" "$T/rotation.v" "$TZ $FAKE_NOW: verdicts, backup (-) and rotation-check.sh (+)"
    v=$(wc -l < "$T/rotation.v")
    [ "$v" -eq "$n" ] || fail "$TZ $FAKE_NOW: $v verdicts for $n archives"
done

t_done
