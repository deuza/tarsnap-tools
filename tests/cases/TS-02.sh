#!/bin/sh
#
# TS-02: without a handler for HUP, closing the terminal left the
# temporary file of tarsnap-stats.sh behind. HUP, INT and TERM now clean
# up and exit with 128 + the signal.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
days www 2026-06-01 3 00-02-02 | set_archives
install_stats

for pair in HUP:129 INT:130 TERM:143; do
    sig=${pair%:*}
    signal_at list "$sig"
    run_script "$T/tarsnap-stats.sh"
    signal_done list
    expect_rc "${pair#*:}" "$sig"
    for f in "$T/tmp"/tarsnap-stats.*; do
        if [ -e "$f" ]; then
            fail "$sig: temporary file left: $f"
            rm -f "$f"
        fi
    done
done

t_done
