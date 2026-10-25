#!/bin/sh
#
# TD-03: a change of type came out identical, and cmp, which follows
# links, opened as root whatever a link pointed to, a FIFO included, and
# hung there. A path whose type differs is now modified at once, and cmp
# only ever reads two regular files: a path replaced by a link to a FIFO
# while tarsnap -x runs is reported as modified, without hanging.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
R=${T#/}/root
mkdir "$T/root/dir2file"
printf 'in\n' > "$T/root/dir2file/inner"
printf 'abc\n' > "$T/root/file2dir"
printf 'abc\n' > "$T/root/a.txt"
ln -s a.txt "$T/root/link2file"
printf 'abc\n' > "$T/root/file2link"
printf 'victim\n' > "$T/root/victim.txt"
snapshot snap1 "$T/root"

rm -rf "$T/root/dir2file" "$T/root/file2dir" "$T/root/link2file" \
    "$T/root/file2link"
printf 'abc\n' > "$T/root/dir2file"
mkdir "$T/root/file2dir"
printf 'abc\n' > "$T/root/link2file"
ln -s a.txt "$T/root/file2link"
# Same size, another date: a candidate for cmp.
touch -d '2026-01-02 00:00:00' "$T/root/victim.txt"
mkfifo "$T/fifo"

hold_on x
run_bg "$T/diff/tarsnap-diff.sh" snap1
if hold_wait x; then
    rm "$T/root/victim.txt"
    ln -s "$T/fifo" "$T/root/victim.txt"
    hold_release x
fi
bg_wait_max 30
expect_rc 0
expect_err 'WARNING: no longer a regular file, verdict forced to "modified":'
for p in dir2file file2dir link2file file2link victim.txt; do
    grep -qxF "* $R/$p" "$T/log/tarsnap-diff.sh-snap1.log" ||
        fail "$p is not reported as modified"
done
if [ -f "$T/watchdog.fired" ]; then
    # Let a cmp blocked on the FIFO go.
    (exec 3<> "$T/fifo") || :
fi

t_done
