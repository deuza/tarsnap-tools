#!/bin/sh
#
# N-R2-10: an absolute exclusion holding a glob was compared literally by
# tarsnap-diff.sh, where tarsnap matches it as a pattern, its "*" crossing
# the "/" too. is_excluded() now uses the pattern unquoted.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
R=${T#/}/root
mkdir -p "$T/root/a/x/cache" "$T/root/b/cache" "$T/root/keep"
printf 'f\n' > "$T/root/a/x/cache/f"
printf 'g\n' > "$T/root/b/cache/g"
printf 'k\n' > "$T/root/keep/k.txt"
set_conf_str BACKUP_EXCLUDE "$T/root/*/cache"
install_diff
snapshot snap1 "$T/root"
rm -rf "$S/store/snap1/$R/a/x/cache" "$S/store/snap1/$R/b/cache"

run_diff snap1
expect_rc 0
expect_out "deleted     (<) : 0"
expect_out "new         (>) : 0"

t_done
