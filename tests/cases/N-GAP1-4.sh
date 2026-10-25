#!/bin/sh
#
# N-GAP1-4: after a reinstall or a rollback the dry run passed while every
# real run failed. A dry run now warns when the account holds archives and
# the file "directory" of the cache directory, read from --dump-config, is
# missing, and says what it does not check.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
printf 'tarsnap --dump-config\nReading from config file: %s\n  cachedir %s\n' \
    "$S/tarsnap.conf" "$T/cache" > "$S/dump"
days www 2026-06-01 5 00-02-02 > "$T/list"

set_archives < "$T/list"
run_backup --dry-run
expect_rc 0
expect_err "WARNING: $T/cache/directory is missing while the account"
expect_err "in step with the server. Run tarsnap --fsck first."
expect_out "Dry-run, not checked: the cache directory against the server,"

: > "$T/cache/directory"
run_backup --dry-run
reject_err "is missing while the account"

rm -f "$T/cache/directory"
: > "$S/archives"
run_backup --dry-run
reject_err "is missing while the account"

set_archives < "$T/list"
run_backup
expect_rc 0 "real run"
reject_err "is missing while the account"

t_done
