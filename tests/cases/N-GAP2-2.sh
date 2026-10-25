#!/bin/sh
#
# N-GAP2-2: find walked what tarsnap -c does not archive: its cache
# directory, and the contents of synthetic file systems mounted under
# BACKUP_DIRS. The walk now leaves them out as tarsnap does, unless
# tarsnap.conf has insane-filesystems. Mounting proc needs root: with -r.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
mkdir "$T/root/cache"
printf 'state\n' > "$T/root/cache/directory"
printf 'tarsnap --dump-config\nReading from config file: %s\n  cachedir %s\n' \
    "$S/tarsnap.conf" "$T/root/cache" > "$S/dump"
printf 'f\n' > "$T/root/f"
snapshot snap1 "$T/root"
rm -rf "$S/store/snap1/$R/cache"

run_diff snap1
expect_rc 0 "cache directory"
expect_out "new         (>) : 0"

if group root; then
    mkdir "$T/root/p"
    rm -rf "$S/store/snap1"
    snapshot snap1 "$T/root"
    rm -rf "$S/store/snap1/$R/cache"
    # The diff in a mount namespace of its own, proc mounted on p.
    cat > "$T/ns.sh" <<NS
mount -t proc proc "$T/root/p" || exit 99
exec $TEST_SHELL "$T/diff/tarsnap-diff.sh" "\$@"
NS
    stub_reset
    RC=0
    (cd "$T" && unshare -m /bin/sh "$T/ns.sh" snap1) \
        < /dev/null > "$T/out" 2> "$T/err" || RC=$?
    expect_rc 0 "proc"
    expect_out "new         (>) : 0"
    printf '  insane-filesystems\n' >> "$S/dump"
    RC=0
    (cd "$T" && unshare -m /bin/sh "$T/ns.sh" snap1) \
        < /dev/null > "$T/out" 2> "$T/err" || RC=$?
    reject_out "new         (>) : 0"
fi

t_done
