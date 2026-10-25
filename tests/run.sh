#!/bin/sh
#
# tests/run.sh
#
# Runs the regression cases of tarsnap-tools under dash, bash and busybox
# sh. Prints nothing when every case passes, and exits with status 0;
# otherwise prints what the failing cases reported, and exits with status
# 1. A case that passes but writes something counts as failed: the suite
# stays silent only when everything is in order.
#
# The cases never run the scripts in place: each one works in a directory
# of its own, created by mktemp and removed at the end, on copies whose
# paths point into it, with a fake tarsnap. Neither the network nor an
# account nor root is needed.
#
# Run it in the foreground. A background job starts with SIGINT and
# SIGQUIT ignored, nohup ignores SIGHUP, and a shell cannot trap again a
# signal ignored when it started: the cases about signals would fail.
#
# usage: tests/run.sh [-s] [-p] [-r] [-t TARSNAP] [-S SHELL] [-k] [CASE...]
#
#   -s          also run the slow checks of tests/slow: rotation-check.sh
#               against the backup replayed night after night, a few
#               minutes per shell
#   -p          also run the checks that need a terminal: the progress
#               line of tarsnap-stats.sh and tarsnap-diff.sh, through
#               script(1), and timing-dependent
#   -r          also run the checks that need root: a device node, a
#               mount namespace
#   -t TARSNAP  also run the checks against a real tarsnap binary, built
#               from the 1.0.41 tag as HACKING.md describes: tarsnap -c
#               --dry-run, without a key, a cache directory or any
#               configuration file
#   -S SHELL    one shell only: dash, bash or busybox
#   -k          keep the directory of a failed case, and print its path
#   CASE        only these cases, by name: TB-01, shared, agreement...
#
# Needs dash, bash, busybox, faketime and the en_US.UTF-8 locale, which
# tarsnap-backup.sh and tarsnap-diff.sh require: on Debian,
# "apt install dash busybox faketime locales", then generate en_US.UTF-8.

set -u

usage() {
    sed -n '/^# usage:/,/^# Needs/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
    exit "${1:-2}"
}

case "$0" in
    */*) TESTS_DIR=${0%/*} ;;
    *)   TESTS_DIR=. ;;
esac
TESTS_DIR=$(CDPATH='' cd -P -- "$TESTS_DIR" && pwd -P) || exit 2

WANT=""
SHELLS="dash bash busybox"
TESTS_TARSNAP=""
TESTS_KEEP=""
while getopts "sprt:S:kh" opt; do
    case "$opt" in
        s) WANT="$WANT slow" ;;
        p) WANT="$WANT pty" ;;
        r) WANT="$WANT root" ;;
        t) WANT="$WANT real"; TESTS_TARSNAP=$OPTARG ;;
        S)
            case "$OPTARG" in
                dash|bash|busybox) SHELLS=$OPTARG ;;
                *) printf 'ERROR: unknown shell: %s\n' "$OPTARG" >&2; usage ;;
            esac
            ;;
        k) TESTS_KEEP=1 ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# --- What the run needs ---
# libfaketime, which the faketime command preloads: found where Debian
# installs it, or asked to the faketime command.
TESTS_FAKETIME_LIB=""
for f in /usr/lib/*/faketime/libfaketime.so.1 /usr/lib/faketime/libfaketime.so.1 \
         /usr/local/lib/faketime/libfaketime.so.1; do
    if [ -f "$f" ]; then
        TESTS_FAKETIME_LIB=$f
        break
    fi
done
if [ -z "$TESTS_FAKETIME_LIB" ] && command -v faketime > /dev/null 2>&1; then
    # The single quotes keep the variable for the shell that faketime starts.
    # shellcheck disable=SC2016
    TESTS_FAKETIME_LIB=$(faketime '2026-01-01 00:00:00' /bin/sh -c \
        'printf "%s" "$LD_PRELOAD"' 2> /dev/null) || TESTS_FAKETIME_LIB=""
fi
missing=""
for c in dash bash busybox mkfifo diff flock awk find sed sort cmp join \
         stdbuf mktemp env; do
    command -v "$c" > /dev/null 2>&1 || missing="$missing $c"
done
[ -n "$TESTS_FAKETIME_LIB" ] || missing="$missing libfaketime"
if ! locale -a 2> /dev/null | grep -qix 'en_US\.utf-\{0,1\}8'; then
    missing="$missing en_US.UTF-8"
fi
case " $WANT " in
    *" pty "*)
        command -v script > /dev/null 2>&1 || missing="$missing script" ;;
esac
if [ -n "$missing" ]; then
    printf 'ERROR: missing for the tests:%s\n' "$missing" >&2
    printf '  on Debian: apt install dash busybox faketime locales,\n' >&2
    printf '  then generate en_US.UTF-8 (dpkg-reconfigure locales)\n' >&2
    exit 2
fi
case " $WANT " in
    *" root "*)
        if [ "$(id -u)" -ne 0 ]; then
            printf 'ERROR: -r needs root\n' >&2
            exit 2
        fi
        ;;
esac
case " $WANT " in
    *" real "*)
        case "$TESTS_TARSNAP" in
            /*) ;;
            *) TESTS_TARSNAP=$(pwd -P)/$TESTS_TARSNAP ;;
        esac
        if [ ! -x "$TESTS_TARSNAP" ]; then
            printf 'ERROR: not an executable: %s\n' "$TESTS_TARSNAP" >&2
            exit 2
        fi
        ;;
esac

# --- The cases ---
CASES=""
if [ "$#" -gt 0 ]; then
    for name do
        if [ -f "$TESTS_DIR/cases/$name.sh" ]; then
            CASES="$CASES $TESTS_DIR/cases/$name.sh"
        elif [ -f "$TESTS_DIR/slow/$name.sh" ]; then
            CASES="$CASES $TESTS_DIR/slow/$name.sh"
            WANT="$WANT slow"
        else
            printf 'ERROR: no case named %s\n' "$name" >&2
            exit 2
        fi
    done
else
    for f in "$TESTS_DIR"/cases/*.sh; do
        [ -f "$f" ] && CASES="$CASES $f"
    done
    case " $WANT " in
        *" slow "*)
            for f in "$TESTS_DIR"/slow/*.sh; do
                [ -f "$f" ] && CASES="$CASES $f"
            done
            ;;
    esac
fi

# --- Running them ---
failed=0
for s in $SHELLS; do
    case "$s" in
        busybox) sh_cmd="busybox sh" ;;
        *)       sh_cmd=$s ;;
    esac
    for f in $CASES; do
        # The shell under test is a list of words: "busybox sh".
        # shellcheck disable=SC2086
        out=$(TESTS_DIR=$TESTS_DIR TEST_SHELL=$sh_cmd TESTS_GROUPS=$WANT \
            TESTS_TARSNAP=$TESTS_TARSNAP TESTS_KEEP=$TESTS_KEEP \
            TESTS_FAKETIME_LIB=$TESTS_FAKETIME_LIB $sh_cmd "$f" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
            failed=$((failed + 1))
            [ -z "$out" ] || printf '%s\n' "$out"
            name=${f##*/}
            if [ "$rc" -eq 0 ]; then
                printf 'FAIL %s [%s]: unexpected output\n' "${name%.sh}" "$sh_cmd"
            elif [ -z "$out" ]; then
                printf 'FAIL %s [%s]: exit status %s\n' "${name%.sh}" "$sh_cmd" "$rc"
            fi
        fi
    done
done

[ "$failed" -eq 0 ]
