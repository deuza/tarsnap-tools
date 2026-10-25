#!/bin/sh
#
# TS-05: a tarsnap binary that could not be run was reported as a rejected
# configuration, exit status 3. Exit statuses 126 and 127 of the first
# call now give exit status 9, with the path of the binary.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init

STATS_TARSNAP="$T/missing"
run_stats
expect_rc 9 "missing binary"
expect_err "cannot run the tarsnap binary: $T/missing"
expect_err "(exit status 127)"

printf '#!/bin/sh\n' > "$T/noexec"
chmod 644 "$T/noexec"
STATS_TARSNAP="$T/noexec"
run_stats
expect_rc 9 "binary not executable"
expect_err "(exit status 126)"

t_done
