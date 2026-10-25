#!/bin/sh
#
# N-R1-10, with TD-16: the listing was split into fields on blanks, so
# that a group name holding a blank shifted every field, and the blanks
# of a name were lost. The listing runs with --numeric-owner, and each
# line is split whole, " -> " being cut for a link only, " link to " for a
# hard link only.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
printf 'a\n' > "$T/root/trail "
printf 'b\n' > "$T/root/x link to y"
ln -s 'trail ' "$T/root/lnk"
snapshot snap1 "$T/root"

run_diff snap1
expect_rc 0
expect_arg tv --numeric-owner
expect_out "deleted     (<) : 0"
expect_out "new         (>) : 0"
expect_out "identical   (=) : 4"

t_done
