#!/bin/sh
#
# RC-03: a replay could only decide the archives of this machine. -H
# names the host of the list, for a list fetched from another machine; it
# means nothing to a simulation.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
days web 2026-06-01 5 00-02-02 > "$T/list"

run_rotation -l "$T/list"
expect_rc 0 "host of this machine"
n=$(grep -c 'outside the pattern, untouchable$' "$T/out")
[ "$n" -eq 5 ] || fail "$n archives of web outside the pattern, expected 5"

run_rotation -H web -l "$T/list"
expect_rc 0 "-H web"
n=$(grep -c 'KEPT  (son, daily)$' "$T/out")
[ "$n" -eq 5 ] || fail "-H web: $n archives kept, expected 5"

run_rotation -H web
expect_rc 1 "-H without -l"
expect_err "ERROR: -H only applies to a replay, with -l"

run_rotation -H "" -l "$T/list"
expect_rc 1 '-H ""'
expect_err "ERROR: -H needs a host name"

t_done
