#!/bin/sh
#
# N-R1-4: without a umask, the dumps of prebackup and the inventories were
# created readable by all. umask 077 makes whatever the script and its
# hooks create private to their owner, whatever the umask of the caller.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cat > "$T/pre.sh" <<HOOK
printf 'dump\n' > "$T/root/dump.sql"
HOOK
add_hook prebackup "$T/pre.sh"

umask 022
run_backup
expect_rc 0
for f in pkg-selections.txt pkg-list.txt pkg-manual.txt dump.sql; do
    expect_mode "$T/root/$f" -rw-------
done

t_done
