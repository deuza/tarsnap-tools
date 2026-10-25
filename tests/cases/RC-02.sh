#!/bin/sh
#
# RC-02: the single trap of rotation-check.sh removed its temporary file
# and let the script go on, which then stopped on an unrelated error, or
# ended with status 0 as if nothing had happened. HUP, INT and TERM now
# clean up and exit with 128 + the signal. The signal reaches a replay
# reading its list from a FIFO, kept in the foreground: a background job
# starts with SIGINT ignored.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_rotation
FAKE_NOW=""

for pair in HUP:129 INT:130 TERM:143; do
    sig=${pair%:*}
    code=${pair#*:}
    rm -f "$T/rc.pid"
    mkfifo "$T/in.$sig"
    # Holds the FIFO open for writing, waits for the script and its
    # temporary directory, sends the signal, then closes the FIFO.
    (
        exec 3> "$T/in.$sig"
        i=0
        until [ -s "$T/rc.pid" ] &&
            ls -d "$T/tmp"/rotation-check.* > /dev/null 2>&1; do
            [ "$i" -lt 300 ] || exit 0
            sleep 0.1
            i=$((i + 1))
        done
        kill "-$sig" "$(cat "$T/rc.pid")"
    ) > /dev/null 2>&1 &
    helper=$!
    RUN_STDIN="$T/in.$sig"
    RUN_PIDFILE="$T/rc.pid"
    run_rotation -l -
    RUN_STDIN=/dev/null
    RUN_PIDFILE=""
    wait "$helper" || :
    expect_rc "$code" "$sig"
    for d in "$T/tmp"/rotation-check.*; do
        if [ -e "$d" ]; then
            fail "$sig: temporary directory left: $d"
            rm -rf "$d"
        fi
    done
done

t_done
