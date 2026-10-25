#!/bin/sh
#
# N-GAP2-4: BACKUP_DIRS was passed to tarsnap without any check, and a
# "//", a "." or a ".." component made tarsnap store other names, under
# which the absolute exclusions no longer matched. check_dirs() refuses
# them, and a relative path, and removes trailing slashes.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup

refused() {
    set_conf_str BACKUP_DIRS "$1"
    run_backup
    expect_rc 1 "BACKUP_DIRS=$1"
    expect_err "ERROR: $2"
    expect_no_call
}

refused "$T/root//a" "BACKUP_DIRS: non-canonical path (//, . or ..): $T/root//a"
refused "$T/root/./a" "BACKUP_DIRS: non-canonical path (//, . or ..): $T/root/./a"
refused "$T/root/a/.." "BACKUP_DIRS: non-canonical path (//, . or ..): $T/root/a/.."
refused "$T/root/.." "BACKUP_DIRS: non-canonical path (//, . or ..): $T/root/.."
refused "relative/dir" "BACKUP_DIRS: not an absolute path: relative/dir"
refused "" "BACKUP_DIRS is empty"

set_conf_str BACKUP_DIRS "$T/root/"
run_backup
expect_rc 0 "trailing slash"
expect_arg c "$T/root"

t_done
