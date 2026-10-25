#!/bin/sh
#
# N-R1-20: with humanize-numbers in tarsnap.conf, --print-stats printed
# "3.0 MB", and every size, ratio and cost of tarsnap-stats.sh came out
# wrong with exit status 0. --no-humanize-numbers goes to every call, and
# a table whose sizes are not plain byte counts is refused, exit status 6.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
days www 2026-06-01 3 00-02-02 | set_archives

run_stats
expect_rc 0 "byte counts"
expect_out "  Total size:       10.00 GB"
for mode in verify list stats; do
    expect_arg "$mode" --no-humanize-numbers
done

{
    printf '%-32s%20s%20s\n' '' 'Total size' 'Compressed size'
    printf '%-32s%20s%20s\n' 'All archives' '3.0 MB' '3.1 MB'
    printf '%-32s%20s%20s\n' '  (unique data)' '1.0 MB' '0.9 MB'
} > "$S/stats"
run_stats
expect_rc 6 "humanized table"
expect_err "unrecognised --print-stats output: the sizes are not plain byte counts"
expect_err 'could not parse the "tarsnap --print-stats" table'

t_done
