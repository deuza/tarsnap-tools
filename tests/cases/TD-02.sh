#!/bin/sh
#
# TD-02: tarsnap-diff.sh evaluated the exclusions otherwise than tarsnap,
# and reported as new the files that tarsnap had left out. is_excluded()
# follows match_exclusion() of tar/matching.c: a pattern starting with /
# or * is matched against the whole path, leading / included, any other
# after each /, both with everything below it.
#
# With -t, the snapshot holds exactly what a real tarsnap -c --dry-run
# archives with the same patterns.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
R=${T#/}/root
mkdir -p "$T/root/.cache" "$T/root/sub/scratch" "$T/root/data/APOD" \
    "$T/root/mirror$T/root/data/APOD" "$T/root/keep"
for f in .cache/c1 sub/scratch/t.txt sub/s.txt data/APOD/img data/d.txt \
    "mirror$T/root/data/APOD/img" keep/k.txt; do
    printf '%s\n' "$f" > "$T/root/$f"
done
set_conf_str BACKUP_EXCLUDE ".cache */scratch $T/root/data/APOD"
install_diff
snapshot snap1 "$T/root"
# What tarsnap left out is not in the archive; the look-alike further down
# the tree is.
rm -rf "$S/store/snap1/$R/.cache" "$S/store/snap1/$R/sub/scratch" \
    "$S/store/snap1/$R/data/APOD"

run_diff snap1
expect_rc 0
expect_out "deleted     (<) : 0"
expect_out "new         (>) : 0"

if group real; then
    "$TESTS_TARSNAP" --no-default-config -c --dry-run -v -f snap2 \
        --exclude=.cache --exclude='*/scratch' \
        --exclude="$T/root/data/APOD" --exclude="$T/root/data/APOD/*" \
        "$T/root" 2> "$T/real.err" || fail "real tarsnap failed"
    sed -n 's/^a //p' "$T/real.err" | LC_ALL=C sort > "$T/archived"
    grep -qx "$R/mirror$T/root/data/APOD/img" "$T/archived" ||
        fail "real tarsnap left out the look-alike"
    snapshot snap2 "$T/root"
    (cd "$S/store/snap2" && find "$R" | LC_ALL=C sort) > "$T/stored"
    comm -23 "$T/stored" "$T/archived" | LC_ALL=C sort -r |
        while IFS= read -r e; do
            rm -rf "$S/store/snap2/$e"
        done
    run_diff snap2
    expect_rc 0 "real tarsnap"
    expect_out "deleted     (<) : 0"
    expect_out "new         (>) : 0"
fi

t_done
