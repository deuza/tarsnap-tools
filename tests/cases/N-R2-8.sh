#!/bin/sh
#
# N-R2-8: find exits with status 1 when an entry vanishes during the walk,
# and set -e dropped the diff after the listing, without a word. An error
# of find now gives a warning and a line in the header of the log.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cat > "$T/bin/find" <<WRAP
#!/bin/sh
/usr/bin/find "\$@"
exit 1
WRAP
chmod +x "$T/bin/find"
install_diff -e "s|^FIND_BIN=.*|FIND_BIN=\"$T/bin/find\"|"
snapshot snap1 "$T/root"

run_diff snap1
expect_rc 0
expect_err "WARNING: find reported errors under $T/root, the inventory may be incomplete"
grep -qxF "# find errors : $T/root" "$T/log/tarsnap-diff.sh-snap1.log" ||
    fail "no line find errors in the header"

t_done
