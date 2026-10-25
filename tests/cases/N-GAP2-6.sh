#!/bin/sh
#
# N-GAP2-6: the simulation counted its days back from now with "-N
# days", which keeps the summer or winter time of the moment: run in the
# hour after midnight, it shifted a whole season by one day, and kept one
# son less than the backup. The days now come from noon of today. At
# 00:02 on 2026-04-15, the backup keeps 91 sons and 153 archives over
# five years, as the slow check against it shows; at noon, 90 and 152.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation

FAKE_NOW="2026-04-15 00:02:00"
run_rotation
expect_rc 0 "00:02"
expect_out "  son         (daily)    : 91"
expect_out "  kept in total          : 153"

FAKE_NOW="2026-04-15 12:00:00"
run_rotation
expect_rc 0 "12:00"
expect_out "  son         (daily)    : 90"
expect_out "  kept in total          : 152"

t_done
