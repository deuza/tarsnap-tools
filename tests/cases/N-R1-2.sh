#!/bin/sh
#
# N-R1-2: getopts stops at the first operand, and everything after it was
# ignored: a mistyped dry-run became a real backup followed by a real
# purge. Any operand is now refused, with the help, before anything runs.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
EN=$(printf '\342\200\223')
EM=$(printf '\342\200\224')

refused() {
    rm -f "$T/root/pkg-selections.txt"
    run_backup "$@"
    expect_rc 1 "$*"
    expect_err "ERROR: unexpected argument:"
    expect_no_call
    if [ -e "$T/root/pkg-selections.txt" ]; then
        fail "$*: prebackup ran"
    fi
}

refused dry-run
refused "${EN}${EN}dry-run"
refused "${EM}dry-run"
refused -v now -n
refused -- -n
refused now --dry-run

t_done
