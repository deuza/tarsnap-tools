#!/bin/sh
#
# N-R1-19: the exclude directives of tarsnap.conf filtered the listing and
# the extraction, on one side only. Both tarsnap calls get
# --no-config-exclude and --no-config-include, and the exclusions of
# tarsnap.conf, read through --dump-config, apply to both sides, shown in
# the header; an include directive is reported, not reproduced.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
printf 'tarsnap --dump-config\nReading from config file: %s\n  exclude *.sql\n  include keep.txt\n' \
    "$S/tarsnap.conf" > "$S/dump"
printf 'dump\n' > "$T/root/dump.sql"
printf 'f\n' > "$T/root/f"
snapshot snap1 "$T/root"
rm "$T/root/dump.sql"
touch -d '2026-01-02 00:00:00' "$T/root/f"

run_diff snap1
expect_rc 0
LOG="$T/log/tarsnap-diff.sh-snap1.log"
if grep -qF "$R/dump.sql" "$LOG"; then
    fail "dump.sql is compared despite the exclusion of tarsnap.conf"
fi
grep -qxF '# tarsnap.conf: *.sql' "$LOG" || fail "no line tarsnap.conf in the header"
expect_err "WARNING: tarsnap.conf has an include directive, which tarsnap-diff.sh does not reproduce: keep.txt"
for mode in tv x; do
    expect_arg "$mode" --no-config-exclude
    expect_arg "$mode" --no-config-include
done

t_done
