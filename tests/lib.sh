#!/bin/sh
#
# tests/lib.sh
#
# Helpers sourced by every case of tests/cases/ and tests/slow/, which
# tests/run.sh runs under dash, bash and busybox sh. A case sources this
# file, calls t_init, installs the scripts it needs, runs them, checks what
# they did, and ends with t_done, whose exit status tells the verdict.
#
# Nothing runs in place. t_init creates a private directory with mktemp
# -d, removed on every way out, and each script is copied there with sed,
# its paths rewritten: binaries replaced by the stubs of tests/stub, key,
# BACKUP_DIRS, lock, inventories, log directory, the installed copy of
# tarsnap-backup.sh and /dev/tty all under that directory. A copy that
# still names a path outside it is refused before it runs, so that a
# rewrite gone wrong never reaches the real system. /dev/null is the only
# real device the scripts open, as a sink.
#
# Variables set by tests/run.sh:
#   TESTS_DIR      absolute path of tests/
#   TEST_SHELL     the shell under test, "busybox sh" being two words
#   TESTS_GROUPS   optional groups requested: slow, pty, root, real
#   TESTS_TARSNAP  the real tarsnap binary of the group real
#   TESTS_KEEP     non-empty: keep the directory of a failed case

set -u

: "${TESTS_DIR:?run the cases through tests/run.sh}"
REPO_DIR=${TESTS_DIR%/*}
TEST_SHELL=${TEST_SHELL:-dash}
TESTS_GROUPS=${TESTS_GROUPS:-}
TESTS_TARSNAP=${TESTS_TARSNAP:-}
TESTS_KEEP=${TESTS_KEEP:-}

CASE=${0##*/}
CASE=${CASE%.sh}
FAILED=0
T=""
RC=0

# The instant of the runs and the time zone. A case changes them before a
# run when it needs another moment; FAKE_NOW empty runs on the real clock.
# libfaketime, preloaded as the faketime command does it, reads the instant
# from $T/faketime at every call and keeps it frozen there: set_now moves
# it while a run is held. TESTS_FAKETIME_LIB, the path of the library, is
# found by tests/run.sh.
FAKE_NOW="2026-06-10 12:00:00"
FT_LIB=${TESTS_FAKETIME_LIB:-}
FT_SHARED=""
TZ=Europe/Paris
export TZ

# A predictable locale for the commands of the cases. The scripts set
# their own where they need one.
unset LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LANGUAGE
LANG=C
export LANG

# Does the run include the optional group $1?
group() {
    case " $TESTS_GROUPS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Records a failure, with the end of what the last run wrote.
fail() {
    printf 'FAIL %s [%s]: %s\n' "$CASE" "$TEST_SHELL" "$*" >&2
    FAILED=1
    if [ -n "$T" ] && [ -s "$T/err" ]; then
        printf '  stderr of the last run:\n' >&2
        sed -n '1,12s/^/  | /p' "$T/err" >&2
    fi
}

# shellcheck disable=SC2317,SC2329
t_cleanup() {
    # The semaphore and the shared memory of libfaketime, see t_init.
    if [ -n "$FT_SHARED" ]; then
        _tc_sem=${FT_SHARED%% *}
        _tc_shm=${FT_SHARED#* }
        rm -f "/dev/shm/sem.${_tc_sem#/}" "/dev/shm/${_tc_shm#/}"
    fi
    if [ -n "$T" ] && [ -d "$T" ]; then
        if [ "$FAILED" -ne 0 ] && [ -n "$TESTS_KEEP" ]; then
            printf '  kept: %s\n' "$T" >&2
        else
            chmod -R u+rwx "$T" 2>/dev/null || :
            rm -rf "$T"
        fi
    fi
}

t_init() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/tarsnap-tests.XXXXXXXX") || {
        printf 'FAIL %s: cannot create a temporary directory\n' "$CASE" >&2
        exit 1
    }
    trap 't_cleanup' EXIT
    trap 't_cleanup; exit 129' HUP
    trap 't_cleanup; exit 130' INT
    trap 't_cleanup; exit 143' TERM
    mkdir "$T/bin" "$T/stub" "$T/root" "$T/run" "$T/cache" "$T/log" \
        "$T/tmp" "$T/sbin" "$T/diff" "$T/rc" "$T/usr" "$T/usr/local" \
        "$T/usr/local/sbin" "$T/stub/listing" "$T/stub/store"
    cp "$TESTS_DIR/stub/tarsnap" "$TESTS_DIR/stub/uname" \
        "$TESTS_DIR/stub/dpkg" "$TESTS_DIR/stub/apt" \
        "$TESTS_DIR/stub/apt-mark" "$TESTS_DIR/stub/logger" "$T/bin/"
    # A wrapper that writes its PID to $1, then execs the rest: the single
    # quotes keep its $$, $1 and $@ for it.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "%%s\\n" "$$" > "$1"\nshift\nexec "$@"\n' \
        > "$T/bin/pidwrap"
    chmod +x "$T/bin/pidwrap"
    STUB_STATE_DIR="$T/stub"
    export STUB_STATE_DIR
    S=$STUB_STATE_DIR
    printf 'www\n' > "$S/hostname"
    : > "$S/archives"
    # Where the scripts create their temporary files.
    TMPDIR="$T/tmp"
    export TMPDIR
    key_plain "$T/tarsnap.key"
    : > "$T/out"
    : > "$T/err"
    if [ -z "$FT_LIB" ]; then
        printf 'FAIL %s: TESTS_FAKETIME_LIB is not set\n' "$CASE" >&2
        exit 1
    fi
    # libfaketime 0.9.10 creates a semaphore and a shared memory object in
    # the first process that preloads it, named after its PID, passes them
    # down through FAKETIME_SHARED, and removes them when that process
    # exits. A run starts with env, which execs the shell and loses that
    # duty: the objects stayed in /dev/shm, and a forked subshell of bash
    # removed them under the feet of the other processes. One pair is made
    # here for the whole case, by a shell that execs true so as not to
    # remove it, and t_cleanup removes it. A PID already used by objects
    # left behind makes the creation fail silently: a few tries.
    printf '%s\n' "$FAKE_NOW" > "$T/faketime"
    _ti_try=0
    while [ -z "$FT_SHARED" ] && [ "$_ti_try" -lt 5 ]; do
        # The single quotes keep the variable for the inner shell.
        # shellcheck disable=SC2016
        FT_SHARED=$(unset FAKETIME_SHARED; env LD_PRELOAD="$FT_LIB" \
            FAKETIME_TIMESTAMP_FILE="$T/faketime" \
            /bin/sh -c 'printf "%s" "${FAKETIME_SHARED:-}"; exec true' \
            2> /dev/null) || FT_SHARED=""
        _ti_try=$((_ti_try + 1))
    done
    if [ -z "$FT_SHARED" ]; then
        printf 'FAIL %s: libfaketime made no shared memory\n' "$CASE" >&2
        exit 1
    fi
}

# The instant of the clock of the runs, YYYY-MM-DD HH:MM:SS, written by a
# rename so that libfaketime never reads a half-written file.
set_now() {
    printf '%s\n' "$1" > "$T/faketime.new"
    mv "$T/faketime.new" "$T/faketime"
}

t_done() {
    exit "$FAILED"
}

# --- Keys ---
# Text key files in the format of tarsnap-keygen, not real keys: the stub
# never reads them, and key_is_passphrased() only looks at the first data
# line, "c2NyeXB0", the base64 of "scrypt", for a protected key.
key_plain() {
    printf '# START OF TARSNAP KEY FILE\n%s\n%s\n# END OF TARSNAP KEY FILE\n' \
        'dGFyc25hcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
        > "$1"
    chmod 600 "$1"
}

key_protected() {
    printf '# START OF TARSNAP KEY FILE\n%s\n%s\n# END OF TARSNAP KEY FILE\n' \
        'c2NyeXB0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
        > "$1"
    chmod 600 "$1"
}

# --- Installing the scripts ---

# Refuses a copy that still holds a path outside $T: $1 is the copy, then
# the names of the variables that must point into $T, each value split on
# blanks for BACKUP_DIRS. A relative path is let through, for the cases of
# paths that the scripts refuse: every run starts in $T. /dev/tty is
# checked apart: it must only appear rewritten, right after a component of
# $T.
guard_copy() {
    _g_file=$1
    shift
    for _g_var do
        _g_val=$(sed -n "s/^$_g_var=\"\\([^\"]*\\)\".*/\\1/p" "$_g_file")
        for _g_word in $_g_val; do
            case "$_g_word" in
                "$T"/*|[!/]*) ;;
                *)
                    printf 'FAIL %s: %s=%s in %s is outside the test directory, not run\n' \
                        "$CASE" "$_g_var" "$_g_word" "$_g_file" >&2
                    exit 1
                    ;;
            esac
        done
    done
    if grep -q '[^A-Za-z0-9._-]/dev/tty' "$_g_file"; then
        printf 'FAIL %s: /dev/tty left in %s, not run\n' "$CASE" "$_g_file" >&2
        exit 1
    fi
}

# Copies tarsnap-backup.sh to $T/sbin, and to the installed path that the
# companion tools look for first, with every path rewritten. BACKUP_DIRS
# becomes $T/root, BACKUP_EXCLUDE empty, the key a plain one.
install_backup() {
    sed -e "s|^TARSNAP_BIN=.*|TARSNAP_BIN=\"$T/bin/tarsnap\"|" \
        -e "s|^UNAME_BIN=.*|UNAME_BIN=\"$T/bin/uname\"|" \
        -e "s|^DPKG_BIN=.*|DPKG_BIN=\"$T/bin/dpkg\"|" \
        -e "s|^APT_BIN=.*|APT_BIN=\"$T/bin/apt\"|" \
        -e "s|^APT_MARK_BIN=.*|APT_MARK_BIN=\"$T/bin/apt-mark\"|" \
        -e "s|^LOGGER_BIN=.*|LOGGER_BIN=\"$T/bin/logger\"|" \
        -e "s|^LAST_SUCCESS=.*|LAST_SUCCESS=\"$T/root/tarsnap-backup.last-success\"|" \
        -e "s|^TARSNAP_KEY=.*|TARSNAP_KEY=\"$T/tarsnap.key\"|" \
        -e "s|^BACKUP_DIRS=.*|BACKUP_DIRS=\"$T/root\"|" \
        -e "s|^BACKUP_EXCLUDE=.*|BACKUP_EXCLUDE=\"\"|" \
        -e "s|^LOCK_FILE=.*|LOCK_FILE=\"$T/run/tarsnap-backup.lock\"|" \
        -e "s|^PKG_SELECTIONS=.*|PKG_SELECTIONS=\"$T/root/pkg-selections.txt\"|" \
        -e "s|^PKG_LIST=.*|PKG_LIST=\"$T/root/pkg-list.txt\"|" \
        -e "s|^PKG_MANUAL=.*|PKG_MANUAL=\"$T/root/pkg-manual.txt\"|" \
        -e "s|/dev/tty|$T/dev/tty|g" \
        "$REPO_DIR/tarsnap-backup.sh" > "$T/sbin/tarsnap-backup.sh"
    sync_backup
}

# After a change to $T/sbin/tarsnap-backup.sh: checks it again, and copies
# it to the installed path of the companion tools.
sync_backup() {
    guard_copy "$T/sbin/tarsnap-backup.sh" TARSNAP_BIN UNAME_BIN DPKG_BIN \
        APT_BIN APT_MARK_BIN LOCK_FILE PKG_SELECTIONS PKG_LIST PKG_MANUAL \
        BACKUP_DIRS LOGGER_BIN LAST_SUCCESS
    _sb_key=$(sed -n 's/^TARSNAP_KEY="\([^"]*\)".*/\1/p' "$T/sbin/tarsnap-backup.sh")
    if [ -n "$_sb_key" ]; then
        guard_copy "$T/sbin/tarsnap-backup.sh" TARSNAP_KEY
    fi
    cp "$T/sbin/tarsnap-backup.sh" "$T/usr/local/sbin/tarsnap-backup.sh"
}

# Sets an unquoted value of the configuration block: set_conf NAME VALUE.
# The value is taken literally, a CR or a # included.
set_conf() {
    _sc_val=$(printf '%s\n' "$2" | sed 's/[\\|&]/\\&/g')
    sed "s|^$1=[^[:blank:]]*|$1=$_sc_val|" "$T/sbin/tarsnap-backup.sh" \
        > "$T/sbin/conf.tmp"
    mv "$T/sbin/conf.tmp" "$T/sbin/tarsnap-backup.sh"
    sync_backup
}

# Same for a quoted value: set_conf_str NAME VALUE.
set_conf_str() {
    _sc_val=$(printf '%s\n' "$2" | sed 's/[\\|&]/\\&/g')
    sed "s|^$1=\"[^\"]*\"|$1=\"$_sc_val\"|" "$T/sbin/tarsnap-backup.sh" \
        > "$T/sbin/conf.tmp"
    mv "$T/sbin/conf.tmp" "$T/sbin/tarsnap-backup.sh"
    sync_backup
}

# Makes a hook source a file of the case first: add_hook prebackup FILE.
# The code runs inside the function, hence in the subshell of run_hook().
add_hook() {
    sed "/^$1() {\$/a\\
    . \"$2\"" "$T/sbin/tarsnap-backup.sh" > "$T/sbin/conf.tmp"
    mv "$T/sbin/conf.tmp" "$T/sbin/tarsnap-backup.sh"
    sync_backup
}

# Copies rotation-check.sh to $T/rc, reading the installed copy of $T.
install_rotation() {
    sed -e "s|^UNAME_BIN=.*|UNAME_BIN=\"$T/bin/uname\"|" \
        -e "s|^BACKUP_SCRIPT_INSTALLED=.*|BACKUP_SCRIPT_INSTALLED=\"$T/usr/local/sbin/tarsnap-backup.sh\"|" \
        "$REPO_DIR/rotation-check.sh" > "$T/rc/rotation-check.sh"
    guard_copy "$T/rc/rotation-check.sh" UNAME_BIN BACKUP_SCRIPT_INSTALLED
}

# Copies tarsnap-diff.sh to $T/diff. Extra sed expressions may follow, to
# replace a binary by a wrapper of the case.
install_diff() {
    sed -e "s|^TARSNAP_BIN=.*|TARSNAP_BIN=\"$T/bin/tarsnap\"|" \
        -e "s|^LOG_DIR=.*|LOG_DIR=\"$T/log\"|" \
        -e "s|^BACKUP_SCRIPT_INSTALLED=.*|BACKUP_SCRIPT_INSTALLED=\"$T/usr/local/sbin/tarsnap-backup.sh\"|" \
        -e "s|/dev/tty|$T/dev/tty|g" \
        "$@" "$REPO_DIR/tarsnap-diff.sh" > "$T/diff/tarsnap-diff.sh"
    guard_copy "$T/diff/tarsnap-diff.sh" TARSNAP_BIN LOG_DIR \
        BACKUP_SCRIPT_INSTALLED
}

# --- Running ---
# Every run starts in $T, reads RUN_STDIN, /dev/null by default, writes
# $T/out and $T/err, and leaves its exit status in RC. The log of the stub
# starts afresh with each run. SHELL_OPTS goes to the shell, -x for a
# trace. With RUN_PIDFILE set, the PID of the shell under test is written
# there as it starts.
SHELL_OPTS=""
RUN_STDIN=/dev/null
RUN_PIDFILE=""

stub_reset() {
    rm -f "$S"/call.* "$S/calls" "$S/n" "$S/logger"
    : > "$S/calls"
}

# $1 is the script, the rest its arguments.
run_script() {
    _rs_script=$1
    shift
    stub_reset
    RC=0
    # pidwrap writes its PID, then execs the shell under test, which keeps
    # it. No blank in the paths: the words split as they should.
    _rs_wrap=""
    if [ -n "$RUN_PIDFILE" ]; then
        _rs_wrap="$T/bin/pidwrap $RUN_PIDFILE"
    fi
    if [ -n "$FAKE_NOW" ]; then
        set_now "$FAKE_NOW"
        # The shell under test is a list of words: "busybox sh".
        # shellcheck disable=SC2086
        (cd "$T" && exec env LD_PRELOAD="$FT_LIB" FAKETIME_SHARED="$FT_SHARED" \
            FAKETIME_TIMESTAMP_FILE="$T/faketime" FAKETIME_NO_CACHE=1 \
            $_rs_wrap $TEST_SHELL $SHELL_OPTS "$_rs_script" "$@") \
            < "$RUN_STDIN" > "$T/out" 2> "$T/err" || RC=$?
    else
        # shellcheck disable=SC2086
        (cd "$T" && exec $_rs_wrap $TEST_SHELL $SHELL_OPTS "$_rs_script" "$@") \
            < "$RUN_STDIN" > "$T/out" 2> "$T/err" || RC=$?
    fi
}

run_backup() {
    run_script "$T/sbin/tarsnap-backup.sh" "$@"
}

run_rotation() {
    run_script "$T/rc/rotation-check.sh" "$@"
}

run_diff() {
    run_script "$T/diff/tarsnap-diff.sh" "$@"
}

# tarsnap-stats.sh takes its tarsnap from TARSNAP and the rest from PATH:
# it is copied as is, and TARSNAP names the stub, unless the case sets
# STATS_TARSNAP.
install_stats() {
    cp "$REPO_DIR/tarsnap-stats.sh" "$T/tarsnap-stats.sh"
    TARSNAP=${STATS_TARSNAP:-$T/bin/tarsnap}
    export TARSNAP
}

run_stats() {
    install_stats
    run_script "$T/tarsnap-stats.sh" "$@"
}

# Same, in the background: BG_PID is the process of the shell, and
# bg_wait leaves the exit status in RC.
run_bg() {
    _rb_script=$1
    shift
    stub_reset
    if [ -n "$FAKE_NOW" ]; then
        set_now "$FAKE_NOW"
        # shellcheck disable=SC2086
        (cd "$T" && exec env LD_PRELOAD="$FT_LIB" FAKETIME_SHARED="$FT_SHARED" \
            FAKETIME_TIMESTAMP_FILE="$T/faketime" FAKETIME_NO_CACHE=1 \
            $TEST_SHELL $SHELL_OPTS "$_rb_script" "$@") \
            < /dev/null > "$T/out" 2> "$T/err" &
    else
        # shellcheck disable=SC2086
        (cd "$T" && exec $TEST_SHELL $SHELL_OPTS "$_rb_script" "$@") \
            < /dev/null > "$T/out" 2> "$T/err" &
    fi
    BG_PID=$!
}

bg_wait() {
    RC=0
    wait "$BG_PID" || RC=$?
}

# bg_wait_max SECONDS: the same, for a run that a regression would block
# forever: past that delay, a watchdog kills it and the case fails.
bg_wait_max() {
    rm -f "$T/watchdog.fired"
    (
        sleep "$1"
        : > "$T/watchdog.fired"
        kill -9 "$BG_PID"
    ) > /dev/null 2>&1 &
    _bw_dog=$!
    bg_wait
    kill "$_bw_dog" 2> /dev/null || :
    wait "$_bw_dog" 2> /dev/null || :
    if [ -f "$T/watchdog.fired" ]; then
        fail "the run was still going after $1 s, killed"
    fi
}

# In a pseudo-terminal, through script(1), in the background, without
# faketime: run_pty SCRIPT ARGS. The terminal stays open three seconds
# after the script ends, so that whatever it left behind can still draw
# on it; what was drawn goes to $T/pty. The arguments must hold no blank
# nor quote.
run_pty() {
    _rp_cmd="$TEST_SHELL $*; sleep 3"
    stub_reset
    (cd "$T" && SHELL=/bin/sh exec script -qfc "$_rp_cmd" "$T/pty") \
        < /dev/null > /dev/null 2>&1 &
    BG_PID=$!
}

# Size of a file, in bytes.
size_of() {
    wc -c < "$1" | tr -d ' '
}

# signal_at MODE SIG: during the next run, send SIG to the script as soon
# as it calls the stub in that mode, then let the stub go on; signal_done
# after the run. The run stays in the foreground: a background job starts
# with SIGINT and SIGQUIT ignored, which a shell can no longer trap.
signal_at() {
    hold_on "$1"
    (
        (
            sleep 30
            printf 'timeout\n' > "$S/at.$1"
        ) &
        read -r _sa_pid < "$S/at.$1" || exit 0
        [ "$_sa_pid" != timeout ] || exit 0
        kill "-$2" "$_sa_pid"
        printf 'go\n' > "$S/go.$1"
    ) > /dev/null 2>&1 &
    SIGNALLER=$!
}

signal_done() {
    wait "$SIGNALLER" 2> /dev/null || :
    rm -f "$S/at.$1" "$S/go.$1"
}

# --- Rendezvous with the stub ---
# hold_on MODE before the run, hold_wait MODE once it is started: it
# returns when the stub has reached that mode, HELD_PID being the script
# that called it. hold_release MODE lets the stub go on.

hold_on() {
    mkfifo "$S/at.$1" "$S/go.$1"
}

hold_wait() {
    # The watchdog writes nowhere but to the FIFO: once killed, its sleep
    # must not keep the output of the case open, which tests/run.sh reads
    # to the end.
    (
        sleep 30
        printf 'timeout\n' > "$S/at.$1"
    ) > /dev/null 2>&1 &
    _hw_dog=$!
    read -r HELD_PID < "$S/at.$1" || HELD_PID=timeout
    kill "$_hw_dog" 2>/dev/null || :
    wait "$_hw_dog" 2>/dev/null || :
    if [ "$HELD_PID" = timeout ]; then
        fail "the stub never reached mode $1"
        return 1
    fi
    return 0
}

hold_release() {
    printf 'go\n' > "$S/go.$1"
    rm -f "$S/at.$1" "$S/go.$1"
}

# --- The stub: state and calls ---

# set_archives: the archives of the account, read from standard input.
set_archives() {
    cat > "$S/archives"
}

# Number of calls in mode $1 during the last run.
stub_count() {
    awk -v m="$1" '$2 == m { n++ } END { print n + 0 }' "$S/calls"
}

# Arguments of the last call in mode $1, one per line.
stub_args() {
    _sa_n=$(awk -v m="$1" '$2 == m { n = $1 } END { print n + 0 }' "$S/calls")
    if [ "$_sa_n" -gt 0 ]; then
        cat "$S/call.$_sa_n"
    fi
}

# Archives passed to -d during the last run, one per line, sorted.
stub_deleted() {
    awk '$2 == "d" { print $1 }' "$S/calls" | while read -r _sd_n; do
        cat "$S/call.$_sd_n.f"
    done | LC_ALL=C sort
}

# --- Snapshots for tarsnap-diff.sh ---
# snapshot NAME DIR...: the archive NAME holds DIR..., as they are now.
snapshot() {
    _sn_name=$1
    shift
    mkdir -p "$S/store/$_sn_name"
    : > "$S/store/$_sn_name.roots"
    for _sn_dir do
        _sn_rel=${_sn_dir#/}
        mkdir -p "$S/store/$_sn_name/${_sn_rel%/*}"
        cp -a "$_sn_dir" "$S/store/$_sn_name/$_sn_rel"
        printf '%s\n' "$_sn_rel" >> "$S/store/$_sn_name.roots"
    done
}

# listing_of NAME: the listing that the stub generates for the archive
# NAME, in UTC as tarsnap-diff.sh asks it, saved as its static listing
# for the case to edit.
listing_of() {
    TZ=UTC0 "$T/bin/tarsnap" -tv -f "$1" > "$S/listing.tmp"
    mv "$S/listing.tmp" "$S/listing/$1"
    rm -f "$S"/call.* "$S/n"
    : > "$S/calls"
}

# Detail lines of a log, without the header.
log_details() {
    grep -v '^#' "$1"
}

# --- Checks ---

expect_rc() {
    if [ "$RC" -ne "$1" ]; then
        fail "${2:+$2: }exit status $RC, expected $1"
    fi
}

# expect_out TEXT, expect_err TEXT: the text appears in the output.
expect_out() {
    grep -qF -- "$1" "$T/out" || fail "stdout lacks: $1"
}

expect_err() {
    grep -qF -- "$1" "$T/err" || fail "stderr lacks: $1"
}

reject_out() {
    if grep -qF -- "$1" "$T/out"; then
        fail "stdout holds: $1"
    fi
}

reject_err() {
    if grep -qF -- "$1" "$T/err"; then
        fail "stderr holds: $1"
    fi
}

expect_no_err() {
    if [ -s "$T/err" ]; then
        fail "stderr is not empty"
    fi
}

# expect_calls MODE N: N calls in that mode during the last run.
expect_calls() {
    _ec_n=$(stub_count "$1")
    if [ "$_ec_n" -ne "$2" ]; then
        fail "$_ec_n call(s) of tarsnap in mode $1, expected $2"
    fi
}

expect_no_call() {
    if [ -s "$S/calls" ]; then
        fail "tarsnap was called: $(awk '{ print $2 }' "$S/calls" | tr '\n' ' ')"
    fi
}

# expect_arg MODE TEXT: the last call in that mode had the argument TEXT.
expect_arg() {
    stub_args "$1" | grep -qxF -- "$2" ||
        fail "no argument \"$2\" in the last call of mode $1"
}

reject_arg() {
    if stub_args "$1" | grep -qxF -- "$2"; then
        fail "argument \"$2\" in the last call of mode $1"
    fi
}

# expect_deleted NAME...: exactly these archives went to -d.
expect_deleted() {
    printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort > "$T/deleted.expected"
    stub_deleted > "$T/deleted.actual"
    if ! diff -u "$T/deleted.expected" "$T/deleted.actual" > "$T/deleted.diff"; then
        fail "archives deleted, expected (-) and actual (+):"
        sed 's/^/  /' "$T/deleted.diff" >&2
    fi
}

# expect_same EXPECTED ACTUAL LABEL: two files with the same content.
expect_same() {
    if ! diff -u "$1" "$2" > "$T/same.diff"; then
        fail "$3, expected (-) and actual (+):"
        sed -n '1,40s/^/  /p' "$T/same.diff" >&2
    fi
}

# expect_mode FILE MODE: permissions as ls -l shows them, -rw------- say.
expect_mode() {
    # ls is the POSIX way to read the permission string of a file name
    # that the case chose itself.
    # shellcheck disable=SC2012
    _em=$(ls -ld "$1" | cut -c1-10)
    if [ "$_em" != "$2" ]; then
        fail "$1 is $_em, expected $2"
    fi
}

# No raw ESC or CR in the output of the last run.
expect_no_ctl() {
    _ec_c=$(printf '\033\r')
    if grep -q "[$_ec_c]" "$T/out" "$T/err"; then
        fail "raw ESC or CR in the output"
    fi
}

# --- Dates ---
# Lines of archive names, one a day: days HOST FIRST COUNT TIME prints
# HOST-YYYY-MM-DD_TIME for COUNT days from FIRST, TIME as HH-MM-SS. The
# relative item comes first: after a time, "+N days" is read by GNU date
# as a time zone offset.
days() {
    _d_i=0
    while [ "$_d_i" -lt "$3" ]; do
        printf '+%s days %s 12:00\n' "$_d_i" "$2"
        _d_i=$((_d_i + 1))
    done | date -f - "+$1-%F_$4"
}

# Day N days after the day $1, as YYYY-MM-DD; N may be negative.
day_plus() {
    date -d "$2 days $1 12:00" +%F
}
