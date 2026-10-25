#!/bin/sh
#
# N-GAP2-5: the monthly bound, "-N months" of GNU date, moved back at the
# end of some months, so that an archive could be kept, deleted, then kept
# again. The bound now falls on the same day of the month, brought back to
# the last day of a shorter month: from one night to the next, it only
# moves forward. Same in tarsnap-backup.sh and in rotation-check.sh.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
set_conf DAILY 78
set_conf WEEKLY 15
set_conf MONTHLY 6
install_rotation
printf 'www-2025-09-01_00-02-00\n' > "$T/list"

for night in 2026-08-29 2026-08-30 2026-08-31 2026-09-01 2026-09-02 2026-09-03; do
    FAKE_NOW="$night 00:02:00"
    set_archives < "$T/list"
    run_backup --dry-run --verbose
    if grep -q 'kept: www-2025-09-01_00-02-00$' "$T/out"; then
        backup=KEPT
    elif grep -q ' -d -f www-2025-09-01_00-02-00$' "$T/out"; then
        backup=DELETED
    else
        backup=none
    fi
    run_rotation -l "$T/list"
    rotation=$(sed -n 's/^  www-2025-09-01_00-02-00 *\([A-Z]*\).*/\1/p' "$T/out")
    case "$night" in
        2026-09-03) expected=DELETED ;;
        *) expected=KEPT ;;
    esac
    [ "$backup" = "$expected" ] ||
        fail "$night: tarsnap-backup.sh says $backup, expected $expected"
    [ "$rotation" = "$expected" ] ||
        fail "$night: rotation-check.sh says $rotation, expected $expected"
done

t_done
