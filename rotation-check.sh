#!/bin/sh
#
# rotation-check.sh
#
# Diagnostic harness for tarsnap-backup.sh. It touches NEITHER tarsnap, NOR
# the network, NOR any archive: it replays nothing but the decision logic
# of the rotation, line for line.
#
# Two modes:
#
#   - simulation (default)
#       Generates a history of daily archives over N days and counts what
#       each tier would keep.
#       Essential when the machine has only been running for a few weeks:
#       a real --dry-run proves nothing as long as all the archives fall
#       within the daily window.
#
#   - replay (-l)
#       Replays the decision against a real list of archives, read from a
#       file or from standard input:
#           tarsnap --list-archives | ./rotation-check.sh -l -
#
# The retention values are read directly from tarsnap-backup.sh.
#
# The options make it possible to compare a scenario without changing
# anything in that file.

set -euf

DATE_BIN="/usr/bin/date"
UNAME_BIN="/usr/bin/uname"
SED_BIN="/usr/bin/sed"
CAT_BIN="/usr/bin/cat"
MKTEMP_BIN="/usr/bin/mktemp"
RM_BIN="/usr/bin/rm"
SORT_BIN="/usr/bin/sort"

# --- Location of tarsnap-backup.sh ---
# Search order: the installed path below, then, failing that, a
# tarsnap-backup.sh next to the harness, in its own directory, which covers
# the case of a freshly cloned repository.
# The -f option bypasses both.

BACKUP_SCRIPT_INSTALLED="/usr/local/sbin/tarsnap-backup.sh"

DAYS=1825         # simulated horizon, 5 years
LISTFILE=""       # non-empty = replay mode
BACKUP_SCRIPT=""  # non-empty = path forced by -f

# Command-line overrides. Empty = keep the value read from the script under
# test.
OPT_DAILY=""
OPT_WEEKLY=""
OPT_MONTHLY=""
OPT_DOW=""
OPT_DOM=""

# The only place where a binary is called without its absolute path:
# usage() can be reached through -h BEFORE the safeguard loop, and a wrong
# "$CAT_BIN" would make the help fail there instead of displaying it. It is
# also exactly the idiom used by tarsnap-backup.sh and tarsnap-diff.sh.
usage() {
    # The continuation line of the synopsis is aligned under the first
    # option, whatever the name the script was installed under: as many
    # spaces as "usage: " plus that name, counted with parameter expansions
    # only, without any external binary, exactly as in tarsnap-diff.sh.
    _pad="       "
    _rest=${0##*/}
    while [ -n "$_rest" ]; do
        _pad="$_pad "
        _rest=${_rest#?}
    done
    cat >&2 <<EOF
usage: ${0##*/} [-D days] [-f script] [-d DAILY] [-w WEEKLY]
$_pad [-m MONTHLY] [-o DOW] [-M DOM] [-l file|-] [-h]

  -D days     simulation horizon (default $DAYS)
  -f script   path of the tarsnap-backup.sh to read the configuration from
  -d DAILY    override the daily window, in days
  -w WEEKLY   override the weekly window, in weeks
  -m MONTHLY  override the monthly window, in months
  -o DOW      override the day of the week kept, 0=Sunday
  -M DOM      override the day of the month kept
  -l file     replay against a real list of archives, "-" for stdin
  -h          display this help

Without overrides, the five retention values are read from tarsnap-backup.sh.
Search order: $BACKUP_SCRIPT_INSTALLED, then this script's directory.
EOF
    exit "${1:-1}"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while getopts "D:f:d:w:m:o:M:l:h" opt; do
    case "$opt" in
        D) DAYS=$OPTARG ;;
        f) BACKUP_SCRIPT=$OPTARG ;;
        d) OPT_DAILY=$OPTARG ;;
        w) OPT_WEEKLY=$OPTARG ;;
        m) OPT_MONTHLY=$OPTARG ;;
        o) OPT_DOW=$OPTARG ;;
        M) OPT_DOM=$OPTARG ;;
        l) LISTFILE=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

# --- Safeguards ---
# All the configured binaries must be executable. The check comes after the
# options, so that -h keeps working even if one of them is missing.
for bin in "$DATE_BIN" "$UNAME_BIN" "$SED_BIN" "$CAT_BIN" "$MKTEMP_BIN" \
           "$RM_BIN" "$SORT_BIN"; do
    [ -x "$bin" ] || die "binary missing or not executable: $bin"
done

# --- Resolving the script to read ---
if [ -z "$BACKUP_SCRIPT" ]; then
    # ${0%/*} yields the directory, unless $0 contains no slash, in which
    # case it yields $0 itself: hence the case, rather than a dirname.
    case "$0" in
        */*) HERE=${0%/*} ;;
        *)   HERE="." ;;
    esac
    if [ -r "$BACKUP_SCRIPT_INSTALLED" ]; then
        BACKUP_SCRIPT=$BACKUP_SCRIPT_INSTALLED
    elif [ -r "$HERE/tarsnap-backup.sh" ]; then
        BACKUP_SCRIPT="$HERE/tarsnap-backup.sh"
    else
        die "tarsnap-backup.sh found neither in $BACKUP_SCRIPT_INSTALLED nor in $HERE, use -f"
    fi
fi
[ -r "$BACKUP_SCRIPT" ] || die "not readable: $BACKUP_SCRIPT"

# Reading an integer value from the script under test.
#
# The file is NOT sourced: that would trigger its option parsing, its lock
# and, in the end, a real backup.
# An anchored sed is enough. It stops at the first match and, along the
# way, checks that the value really is an integer.
# Anchoring on "^NAME=" rules out namesakes such as DAILY_SEC, which do not
# start with "DAILY=".

read_value() {
    _v=$("$SED_BIN" -n "/^$1=/{s/^$1=\([0-9][0-9]*\).*/\1/p;q;}" "$BACKUP_SCRIPT")
    [ -n "$_v" ] || die "value $1 not found or not numeric in $BACKUP_SCRIPT"
    printf '%s\n' "$_v"
}

DAILY=$(read_value DAILY)
WEEKLY=$(read_value WEEKLY)
MONTHLY=$(read_value MONTHLY)
DOW=$(read_value DOW)
DOM=$(read_value DOM)

# The overrides come after the reading, so that a scenario can be compared
# with the real configuration without touching the script.
# if statements rather than "[ ] && x=y": under set -e, a false test at the
# head of an && list does not stop the script by itself, but the list still
# returns a non-zero status. As the last command of a function, that status
# would kill the script at the call site; as the last command of the
# script, it would become its exit code. An if without else whose test
# fails returns 0, wherever the line ends up.
if [ -n "$OPT_DAILY" ];   then DAILY=$OPT_DAILY;     fi
if [ -n "$OPT_WEEKLY" ];  then WEEKLY=$OPT_WEEKLY;   fi
if [ -n "$OPT_MONTHLY" ]; then MONTHLY=$OPT_MONTHLY; fi
if [ -n "$OPT_DOW" ];     then DOW=$OPT_DOW;         fi
if [ -n "$OPT_DOM" ];     then DOM=$OPT_DOM;         fi

# Same calculations as the script under test: CUMULATIVE windows, each tier
# takes over where the previous one stops.
NOW_UNIX=$("$DATE_BIN" +%s)
DAILY_SEC=$((DAILY * 86400))
WEEKLY_SEC=$((DAILY_SEC + WEEKLY * 604800))
MONTHLY_UNIX=$(($("$DATE_BIN" -d "-${MONTHLY} months" +%s) - WEEKLY_SEC))

TMP=$("$MKTEMP_BIN") || exit 1
trap '"$RM_BIN" -f "$TMP"' EXIT HUP INT TERM

printf 'tarsnap-backup: rotation consistency check\n'
printf -- '------------------------------------------\n'
printf 'configuration read from %s\n\n' "$BACKUP_SCRIPT"
printf 'daily      DAILY=%-4s all              from %5s to %5s d\n' \
    "$DAILY" 0 "$((DAILY_SEC / 86400))"
printf 'weekly     WEEKLY=%-3s DOW=%s            from %5s to %5s d\n' \
    "$WEEKLY" "$DOW" "$((DAILY_SEC / 86400))" "$((WEEKLY_SEC / 86400))"
printf 'monthly    MONTHLY=%-2s DOM=%-2s           from %5s to %5s d\n\n' \
    "$MONTHLY" "$DOM" "$((WEEKLY_SEC / 86400))" \
    "$(((NOW_UNIX - MONTHLY_UNIX) / 86400))"

# Invariant: each tier must open a window STRICTLY wider than the previous
# one, otherwise its test is unreachable and the tier is useless.
# With cumulative windows the invariant is structural: each bound is
# computed from the previous one, a tier can no longer be swallowed by its
# neighbour.
# What remains are the cases where a tier is set to zero, hence disabled in
# practice.
ANOMALIE=0
if [ "$WEEKLY" -lt 1 ]; then
    ANOMALIE=1
    printf 'WARNING: WEEKLY=%s, the weekly tier is disabled.\n\n' \
        "$WEEKLY"
fi
if [ "$MONTHLY_UNIX" -ge "$((NOW_UNIX - WEEKLY_SEC))" ]; then
    ANOMALIE=1
    printf 'WARNING: MONTHLY=%s does not extend beyond the weekly window,\n' \
        "$MONTHLY"
    printf '         the monthly tier is disabled.\n\n'
fi

# Decision for one archive, from its epoch, its day of the week and its day
# of the month. Writes the verdict into DECISION: son, father, gfather or
# purge.
decide() {
    _unix=$1; _dow=$2; _dom=$3
    _age=$((NOW_UNIX - _unix))
    if [ "$_age" -lt "$DAILY_SEC" ]; then
        DECISION=son
    elif [ "$_dow" -eq "$DOW" ] && [ "$_age" -lt "$WEEKLY_SEC" ]; then
        DECISION=father
    elif [ "$_dom" -eq "$DOM" ] && [ "$_unix" -gt "$MONTHLY_UNIX" ]; then
        DECISION=gfather
    else
        DECISION=purge
    fi
}

# Replay mode: prints the name of an archive, indented by two spaces and
# padded to NAME_WIDTH, then its verdict. The padding is counted with
# parameter expansions, as in usage(), so the printf format stays constant.
print_verdict() {
    _name=$1
    while [ "${#_name}" -lt "$NAME_WIDTH" ]; do
        _name="$_name "
    done
    printf '  %s %s\n' "$_name" "$2"
}

kd=0; kw=0; km=0; del=0; skip=0

if [ -n "$LISTFILE" ]; then
    ###########################################################################
    # REPLAY MODE against a real list
    ###########################################################################
    COMPUTER=$("$UNAME_BIN" -n)
    if [ "$LISTFILE" = "-" ]; then
        "$CAT_BIN" > "$TMP"
    else
        "$CAT_BIN" "$LISTFILE" > "$TMP"
    fi

    # tarsnap lists the archives in no particular order. Sorted by name in
    # the C locale, they come out grouped by host and, within each host, in
    # chronological order, since the timestamp has a fixed width.
    LC_ALL=C "$SORT_BIN" -o "$TMP" "$TMP"

    # Width of the name column: at least 32 characters, widened to the
    # longest name of the list, so that a long snapshot name does not shift
    # the verdicts.
    NAME_WIDTH=32
    while read -r archive; do
        if [ "${#archive}" -gt "$NAME_WIDTH" ]; then
            NAME_WIDTH=${#archive}
        fi
    done < "$TMP"

    printf 'Replay against the real list, hostname "%s":\n\n' "$COMPUTER"

    while read -r archive; do
        [ -n "$archive" ] || continue
        case "$archive" in
            *.part)
                print_verdict "$archive" "PARTIAL, left in place"
                skip=$((skip + 1)); continue ;;
            "${COMPUTER}-"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
                ;;
            *)
                print_verdict "$archive" "outside the pattern, untouchable"
                skip=$((skip + 1)); continue ;;
        esac

        stamp=${archive#"${COMPUTER}-"}
        day=${stamp%%_*}
        # shellcheck disable=SC2046
        set -- $("$DATE_BIN" -d "$day" '+%s %w %-d')
        decide "$1" "$2" "$3"

        case "$DECISION" in
            son)     kd=$((kd + 1));   verdict="KEPT  (son, daily)" ;;
            father)  kw=$((kw + 1));   verdict="KEPT  (father, weekly)" ;;
            gfather) km=$((km + 1));   verdict="KEPT  (grandfather, monthly)" ;;
            *)       del=$((del + 1)); verdict="DELETED" ;;
        esac
        print_verdict "$archive" "$verdict"
    done < "$TMP"
    printf '\n'
else
    ###########################################################################
    # SIMULATION MODE
    ###########################################################################
    printf 'Simulation over %s days, one archive per day...\n' "$DAYS"

    # Two calls to date for the whole history, instead of four per day: the
    # previous version forked 7300 times for 5 years and looked as if it had
    # hung.
    # First pass: the relative dates become YYYY-MM-DD.
    # Second pass: those days become the epoch at midnight, the day of the
    # week and the day of the month, exactly as the script under test does.
    i=0
    while [ "$i" -lt "$DAYS" ]; do
        printf -- '-%s days\n' "$i"
        i=$((i + 1))
    done | "$DATE_BIN" -f - +%F | "$DATE_BIN" -f - '+%s %w %-d' > "$TMP"

    while read -r f_unix f_dow f_dom; do
        decide "$f_unix" "$f_dow" "$f_dom"
        case "$DECISION" in
            son)     kd=$((kd + 1)) ;;
            father)  kw=$((kw + 1)) ;;
            gfather) km=$((km + 1)) ;;
            *)       del=$((del + 1)) ;;
        esac
    done < "$TMP"
    printf '\n'
fi

printf '  son         (daily)    : %s\n' "$kd"
printf '  father      (weekly)   : %s\n' "$kw"
printf '  grandfather (monthly)  : %s\n' "$km"
printf '  deleted                : %s\n' "$del"
[ "$skip" -gt 0 ] && printf '  outside the rotation   : %s\n' "$skip"
printf '  ----------------------------------\n'
printf '  kept in total          : %s\n\n' "$((kd + kw + km))"

if [ "$kw" -eq 0 ] && [ "$ANOMALIE" -eq 1 ]; then
    printf 'CONCLUSION: the father tier keeps nothing.\n'
fi
if [ "$ANOMALIE" -eq 0 ] && [ -z "$LISTFILE" ]; then
    printf 'All three tiers are active, the configuration is consistent.\n'
fi
exit 0
