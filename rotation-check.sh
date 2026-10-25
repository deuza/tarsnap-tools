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
#       The archives are those of this machine, or of the host named by -H.
#       The nights to come are then projected, to tell those where the
#       breaker of tarsnap-backup.sh, MAX_PURGE, would stop the purge.
#
# The retention values are read directly from tarsnap-backup.sh, and so is
# MAX_PURGE, the purge circuit breaker.
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
DAYS_SET=0        # 1 = -D given, which also sets the nights projected
LISTFILE=""       # non-empty = replay mode
BACKUP_SCRIPT=""  # non-empty = path forced by -f

# Command-line overrides. Empty = keep the value read from the script under
# test.
OPT_DAILY=""
OPT_WEEKLY=""
OPT_MONTHLY=""
OPT_DOW=""
OPT_DOM=""
OPT_MAX_PURGE=""  # breaker, set by -b
OPT_HOST=""       # host of the replayed archives, set by -H
HOST_SET=0

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
usage: ${0##*/} [-h] [-D days] [-f script] [-l file|-] [-H host]
$_pad [-d DAILY] [-w WEEKLY] [-m MONTHLY] [-o DOW] [-M DOM]
$_pad [-b count]

  -D days     simulation horizon (default $DAYS), or nights projected after
              a replay (default DAILY + 1)
  -f script   path of the tarsnap-backup.sh to read the configuration from
  -d DAILY    override the daily window, in days
  -w WEEKLY   override the weekly window, in weeks
  -m MONTHLY  override the monthly window, in months
  -o DOW      override the day of the week kept, 0=Sunday
  -M DOM      override the day of the month kept
  -b count    override MAX_PURGE, the most archives a run may delete
  -l file     replay against a real list of archives, "-" for stdin
  -H host     host of the replayed archives, instead of this machine
  -h          display this help

Without overrides, all six values are read from tarsnap-backup.sh.
Search order: $BACKUP_SCRIPT_INSTALLED, then this script's directory.
EOF
    exit "${1:-1}"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while getopts "D:f:d:w:m:o:M:l:H:b:h" opt; do
    case "$opt" in
        D) DAYS=$OPTARG; DAYS_SET=1 ;;
        f) BACKUP_SCRIPT=$OPTARG ;;
        d) OPT_DAILY=$OPTARG ;;
        w) OPT_WEEKLY=$OPTARG ;;
        m) OPT_MONTHLY=$OPTARG ;;
        o) OPT_DOW=$OPTARG ;;
        M) OPT_DOM=$OPTARG ;;
        l) LISTFILE=$OPTARG ;;
        H) OPT_HOST=$OPTARG; HOST_SET=1 ;;
        b) OPT_MAX_PURGE=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

# getopts stops at the first operand and leaves it, with everything after
# it, in $@. The script takes none: an operand is a mistyped option, such
# as "l -" without its dash, which used to run a simulation and ignore the
# list without a word. Refused, with the help, as in tarsnap-backup.sh.
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
    printf 'ERROR: unexpected argument: %s\n' "$1" >&2
    printf '  options start with an ASCII "-", and a dash pasted from a\n' >&2
    printf '  document is not one\n' >&2
    usage 1
fi

# -H names the host whose archives a replay decides, for a list fetched
# from another machine (RC-03). It means nothing to a simulation.
if [ "$HOST_SET" -eq 1 ]; then
    if [ -z "$LISTFILE" ]; then
        die "-H only applies to a replay, with -l"
    fi
    if [ -z "$OPT_HOST" ]; then
        die "-H needs a host name"
    fi
fi

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
    if [ -e "$BACKUP_SCRIPT_INSTALLED" ]; then
        # An installed copy that cannot be read stops the tool, instead of
        # a silent fall back on the copy of the repository: production
        # often runs with other values, and the result would describe a
        # rotation that cron never runs (N-R1-21, RC-05).
        if [ ! -r "$BACKUP_SCRIPT_INSTALLED" ]; then
            die "$BACKUP_SCRIPT_INSTALLED exists but is not readable," \
                "run as root or use -f"
        fi
        BACKUP_SCRIPT=$BACKUP_SCRIPT_INSTALLED
    elif [ -r "$HERE/tarsnap-backup.sh" ]; then
        BACKUP_SCRIPT="$HERE/tarsnap-backup.sh"
    else
        die "tarsnap-backup.sh found neither in $BACKUP_SCRIPT_INSTALLED nor in $HERE, use -f"
    fi
fi
[ -r "$BACKUP_SCRIPT" ] || die "not readable: $BACKUP_SCRIPT"

# Reading a value from the script under test, as the shell would assign
# it.
#
# The file is NOT sourced: that would trigger its option parsing, its lock
# and, in the end, a real backup.
# The value is the first word after "NAME=", up to a blank or to one of the
# characters that end a word for the shell, ;&|<>(), and it is kept whole:
# "1#Monday", or "1" followed by the CR of DOS line endings, reach
# check_retention() as they are and are refused there, as tarsnap-backup.sh
# refuses them. Keeping only the leading digits used to announce a rotation
# that the backup would never run (N-R1-7).
# A quoted value is refused with its own message, the expected form being
# unquoted (HACKING.md), and so is a second line assigning the same name:
# the shell keeps the last assignment, and a tool reading the first one
# would read another value than the backup.
# Anchoring on "^NAME=" rules out namesakes such as DAILY_SEC, which do not
# start with "DAILY=".

read_value() {
    _lines=$("$SED_BIN" -n "/^$1=/=" "$BACKUP_SCRIPT")
    case "$_lines" in
        "")
            die "value $1 not found in $BACKUP_SCRIPT" ;;
        *[!0123456789]*)
            die "$1 is assigned on more than one line in $BACKUP_SCRIPT" ;;
    esac
    _v=$("$SED_BIN" -n \
        "${_lines}s/^$1=\([^[:blank:];&|<>()]*\).*/\1/p" "$BACKUP_SCRIPT")
    case "$_v" in
        \"*|\'*)
            die "$1 is quoted in $BACKUP_SCRIPT, write it without quotes" ;;
    esac
    printf '%s\n' "$_v"
}

# Retention values, refused under the same conditions as in
# tarsnap-backup.sh: decimal integers without a leading zero, which the
# shell would read as octal, five digits at most, DAILY of at least 1, DOW
# from 0 to 6 as date +%w counts, DOM from 1 to 31. Out-of-range values
# used to pass here and end with "consistent" (RC-01). The function is a
# copy of the one in tarsnap-backup.sh and must stay identical to it, byte
# for byte, see HACKING.md: a value the backup refuses is refused here, and
# only such a value.
check_retention() {
    set -- DAILY "$DAILY" WEEKLY "$WEEKLY" MONTHLY "$MONTHLY" \
        DOW "$DOW" DOM "$DOM"
    while [ "$#" -ge 2 ]; do
        case "$2" in
            ""|*[!0123456789]*|0?*)
                die "$1 must be a decimal integer, without a leading zero"
                ;;
            ??????*)
                die "$1 must have at most 5 digits"
                ;;
        esac
        shift 2
    done
    if [ "$DAILY" -lt 1 ]; then
        die "DAILY must be at least 1"
    fi
    if [ "$DOW" -gt 6 ]; then
        die "DOW must be between 0 (Sunday) and 6 (Saturday)"
    fi
    if [ "$DOM" -lt 1 ] || [ "$DOM" -gt 31 ]; then
        die "DOM must be between 1 and 31"
    fi
    return 0
}

# MAX_PURGE, refused under the same conditions as in tarsnap-backup.sh. The
# function is a copy of the one in tarsnap-backup.sh and must stay
# identical to it, byte for byte, see HACKING.md.
check_max_purge() {
    case "$MAX_PURGE" in
        ""|*[!0123456789]*|0*|??????*)
            die "MAX_PURGE must be a decimal integer from 1 to 99999," \
                "without a leading zero" ;;
    esac
    return 0
}

DAILY=$(read_value DAILY)
WEEKLY=$(read_value WEEKLY)
MONTHLY=$(read_value MONTHLY)
DOW=$(read_value DOW)
DOM=$(read_value DOM)
# The purge circuit breaker of tarsnap-backup.sh. A file without it stops
# the tool, as any missing value: such a backup predates the rotation that
# decide() replays, and would decide otherwise anyway.
MAX_PURGE=$(read_value MAX_PURGE)

# The values of the file are checked before the overrides, so that an
# option cannot hide a value that the backup would refuse. Since
# check_retention() must not change, it does not say where a value comes
# from: it runs in a subshell, and a second line names the source.
( check_retention ) || die "value read from $BACKUP_SCRIPT"
( check_max_purge ) || die "value read from $BACKUP_SCRIPT"

# The overrides come after the reading, so that a scenario can be compared
# with the real configuration without touching the script.
# if statements rather than "[ ] && x=y": under set -e, a false test at the
# head of an && list does not stop the script by itself, but the list still
# returns a non-zero status. As the last command of a function, that status
# would kill the script at the call site; as the last command of the
# script, it would become its exit code. An if without else whose test
# fails returns 0, wherever the line ends up.
# Values of the file, kept for the simulation of a change to the values
# given as options.
FILE_DAILY=$DAILY; FILE_WEEKLY=$WEEKLY; FILE_MONTHLY=$MONTHLY
FILE_DOW=$DOW; FILE_DOM=$DOM
if [ -n "$OPT_DAILY" ];   then DAILY=$OPT_DAILY;     fi
if [ -n "$OPT_WEEKLY" ];  then WEEKLY=$OPT_WEEKLY;   fi
if [ -n "$OPT_MONTHLY" ]; then MONTHLY=$OPT_MONTHLY; fi
if [ -n "$OPT_DOW" ];     then DOW=$OPT_DOW;         fi
if [ -n "$OPT_DOM" ];     then DOM=$OPT_DOM;         fi
if [ -n "$OPT_MAX_PURGE" ]; then MAX_PURGE=$OPT_MAX_PURGE; fi
( check_retention ) || die "value given on the command line"
( check_max_purge ) || die "value given on the command line"

# The simulated horizon follows the same rules, from 1 to 99999 days. It is
# not a retention value and stays out of check_retention(), which must not
# drift from the one of tarsnap-backup.sh.
case "$DAYS" in
    ""|*[!0123456789]*|0*|??????*)
        die "-D must be a decimal integer from 1 to 99999," \
            "without a leading zero" ;;
esac

# Same calculations as tarsnap-backup.sh, line for line: CUMULATIVE
# windows, each tier takes over where the previous one stops.
NOW_UNIX=$("$DATE_BIN" +%s)
DAILY_SEC=$((DAILY * 86400))
WEEKLY_SEC=$((DAILY_SEC + WEEKLY * 604800))
#
# The monthly bound is MONTHLY months before today, on the same day of the
# month, brought back to the last day of that month when it is shorter.
# "date -d -N months" would instead spill over into the following month
# (31 August minus 6 months gives 3 March): the bound would then move back
# at the end of some months, and an archive could be kept, deleted, then
# kept again. Noon, for the days without midnight.
MONTHLY_DAY=$("$DATE_BIN" +%-d)
MONTHLY_YM=$("$DATE_BIN" +%Y-%m-15)
MONTHLY_YM=$("$DATE_BIN" -d "$MONTHLY_YM 12:00 ${MONTHLY} months ago" +%Y-%m)
MONTHLY_LAST=$("$DATE_BIN" -d "${MONTHLY_YM}-15 12:00 1 month" +%Y-%m-01)
MONTHLY_LAST=$("$DATE_BIN" -d "$MONTHLY_LAST 12:00 1 day ago" +%-d)
if [ "$MONTHLY_DAY" -gt "$MONTHLY_LAST" ]; then
    MONTHLY_DAY=$MONTHLY_LAST
fi
MONTHLY_UNIX=$("$DATE_BIN" -d "${MONTHLY_YM}-${MONTHLY_DAY} 12:00" +%s)
MONTHLY_UNIX=$((MONTHLY_UNIX - WEEKLY_SEC))

# Temporary files, all in one directory, removed whatever the way out.
#
# SC2317 and SC2329 are disabled here: shellcheck does not follow calls
# made from a trap, and therefore believes the whole body is dead (SC2317)
# or the function never invoked (SC2329, from ShellCheck 0.11.0 on). It is
# not.
# shellcheck disable=SC2317,SC2329
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        "$RM_BIN" -rf "$TMP_DIR"
    fi
    return 0
}

# The signal handlers EXIT after cleaning up, and that is the whole point
# of separating them from the EXIT trap. The former single trap removed
# the temporary file and let the script carry on: depending on the moment,
# it stopped on an unrelated error, or printed its summary and ended with
# status 0 as if nothing had happened (RC-02). Exit codes 128 + signal
# number, as a shell does. Same handlers as in tarsnap-diff.sh.
TMP_DIR=""
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# mktemp without a template creates $TMPDIR/tmp.XXXXXXXXXX, a name that
# means nothing to anyone when it turns up in an error message. With a
# template, it announces itself.
TMP_DIR=$("$MKTEMP_BIN" -d "${TMPDIR:-/tmp}/rotation-check.XXXXXXXX") \
    || die "cannot create the temporary directory in ${TMPDIR:-/tmp}"
TMP="$TMP_DIR/list"

printf 'tarsnap-backup: rotation consistency check\n'
printf -- '------------------------------------------\n'
printf 'configuration read from %s\n\n' "$BACKUP_SCRIPT"
printf 'daily      DAILY=%-4s all              from %5s to %5s d\n' \
    "$DAILY" 0 "$((DAILY_SEC / 86400))"
printf 'weekly     WEEKLY=%-3s DOW=%s            from %5s to %5s d\n' \
    "$WEEKLY" "$DOW" "$((DAILY_SEC / 86400))" "$((WEEKLY_SEC / 86400))"
printf 'monthly    MONTHLY=%-2s DOM=%-2s           from %5s to %5s d\n' \
    "$MONTHLY" "$DOM" "$((WEEKLY_SEC / 86400))" \
    "$(((NOW_UNIX - MONTHLY_UNIX) / 86400))"
printf 'breaker    MAX_PURGE=%s, the most archives a run may delete\n\n' \
    "$MAX_PURGE"

# Invariant: each tier must open a window STRICTLY wider than the previous
# one, otherwise its test is unreachable and the tier is useless.
# With cumulative windows the invariant is structural: each bound is
# computed from the previous one, a tier can no longer be swallowed by its
# neighbour.
# What remains are the cases where a tier is set to zero: WEEKLY=0 disables
# the weekly tier, MONTHLY=0 leaves the monthly one nothing older than the
# weekly window.
ANOMALIE=0
if [ "$WEEKLY" -lt 1 ]; then
    ANOMALIE=1
    printf 'WARNING: WEEKLY=%s, the weekly tier is disabled.\n\n' \
        "$WEEKLY"
fi
# MONTHLY=0 is tested as such: the monthly bound is now taken at noon, and
# comparing it with the end of the weekly window only caught MONTHLY=0 in
# the morning.
if [ "$MONTHLY" -lt 1 ]; then
    ANOMALIE=1
    printf 'WARNING: MONTHLY=%s does not extend beyond the weekly window,\n' \
        "$MONTHLY"
    printf '         the monthly tier keeps nothing older than it.\n\n'
fi

# Strict stamp of the archive names, YYYY-MM-DD_HH-MM-SS. The digits are
# written in full rather than as the range [0-9]: the content of a range
# depends on the locale, and under bash [0-9] also matches digits other
# than 0 to 9. The expansion is left unquoted where it is used, so that it
# acts as a pattern and not as a literal string.
_digit='[0123456789]'
STAMP_GLOB="${_digit}${_digit}${_digit}${_digit}-${_digit}${_digit}"
STAMP_GLOB="${STAMP_GLOB}-${_digit}${_digit}_${_digit}${_digit}"
STAMP_GLOB="${STAMP_GLOB}-${_digit}${_digit}-${_digit}${_digit}"

# Decision for one archive, taken as in the loop of tarsnap-backup.sh,
# condition for condition: same order, same bounds, same sets of the weeks
# and months already represented, the archives coming in chronological
# order. The caller computes the dates beforehand, with the date
# expressions of the backup, into the globals of the same names:
#   f_unix  midnight of the archive day, as noon minus 12 hours
#   w_key   first day of its week, the last day DOW, as YYYY-MM-DD
#   w_unix  midnight of that first day
#   m_key   month the archive belongs to, counted from day DOM, as YYYY-MM
#   m_unix  midnight of the first day of that month
# Writes the verdict into DECISION: son, father, gfather or purge.
decide() {
    age=$((NOW_UNIX - f_unix))

    # Son: everything that is recent.
    if [ "$age" -lt "$DAILY_SEC" ]; then
        DECISION=son
        return 0
    fi

    # Month of the archive, only while the archive is newer than the
    # monthly bound, as the backup only computes it then: an older month
    # can no longer count.
    if [ "$f_unix" -le "$MONTHLY_UNIX" ]; then
        m_key=""
        m_unix=0
    fi

    # Father: the first archive of each week, a week starting on day DOW,
    # as long as that day lies within the weekly window. A missed night of
    # DOW no longer leaves the week without any archive (N-R2-3). The
    # archive kept also represents its month.
    if [ "$age" -lt "$WEEKLY_SEC" ]; then
        if [ $((NOW_UNIX - w_unix)) -lt "$WEEKLY_SEC" ]; then
            case "$SEEN_WEEKS" in
                *" $w_key "*) ;;
                *)
                    SEEN_WEEKS="$SEEN_WEEKS$w_key "
                    SEEN_MONTHS="$SEEN_MONTHS$m_key "
                    DECISION=father
                    return 0
                    ;;
            esac
        fi
    fi

    # Grandfather: the first archive of each month, as long as its first
    # day lies within the monthly window (N-R2-3).
    if [ -n "$m_key" ] && [ "$m_unix" -gt "$MONTHLY_UNIX" ]; then
        case "$SEEN_MONTHS" in
            *" $m_key "*) ;;
            *)
                SEEN_MONTHS="$SEEN_MONTHS$m_key "
                DECISION=gfather
                return 0
                ;;
        esac
    fi

    DECISION=purge
    return 0
}

# Prints an archive name with every byte outside printable ASCII replaced
# by "?": a name holding ESC or CR would otherwise drive the terminal of
# root, or garble the cron mail.
shown() {
    printf '%s\n' "$1" | LC_ALL=C "$SED_BIN" 's/[^ -~]/?/g'
}

# Replay mode: prints the name of an archive as shown() gives it, so that
# its control characters cannot drive the terminal (N-R2-4), indented by
# two spaces and padded to NAME_WIDTH, then its verdict. The padding is
# counted with parameter expansions, as in usage(), so the printf format
# stays constant.
print_verdict() {
    _name=$(shown "$1")
    while [ "${#_name}" -lt "$NAME_WIDTH" ]; do
        _name="$_name "
    done
    printf '  %s %s\n' "$_name" "$2"
}

# Dates that decide() needs, for a list of days, with the date expressions
# of tarsnap-backup.sh and of the replay, in a few calls to date, each fed
# one expression per line: archive by archive, five years would take some
# 9000 forks, and the tool looked as if it had hung at 7300. Reads the
# days, YYYY-MM-DD one per line, from "$1", and writes to "$2" one line
# per day, in the same order: "f_unix w_key w_unix m_key m_unix".
date_days() {
    # Noon of each day: epoch and day of the week.
    "$SED_BIN" 's/$/ 12:00/' "$1" |
        "$DATE_BIN" -f - '+%s %w' > "$TMP_DIR/noon"

    # Two lines per day: the first day of its week, then the day that
    # names its month, DOM - 1 days earlier.
    while IFS= read -r day <&3 && read -r f_noon f_dow <&4; do
        w_back=$(( (f_dow - DOW + 7) % 7 ))
        printf -- '-%s days %s 12:00\n' "$w_back" "$day"
        printf -- '-%s days %s 12:00\n' "$((DOM - 1))" "$day"
    done 3< "$1" 4< "$TMP_DIR/noon" |
        "$DATE_BIN" -f - '+%F %s %Y-%m' > "$TMP_DIR/periods"

    # First day of each of those months.
    while read -r _ && read -r _ _ m_key; do
        printf '+%s days %s-01 12:00\n' "$((DOM - 1))" "$m_key"
    done < "$TMP_DIR/periods" | "$DATE_BIN" -f - +%s > "$TMP_DIR/months"

    while read -r f_noon _ <&3 && read -r w_key w_epoch _ <&4 &&
        read -r _ _ m_key <&4 && read -r m_ref <&5; do
        printf '%s %s %s %s %s\n' "$((f_noon - 43200))" "$w_key" \
            "$((w_epoch - 43200))" "$m_key" "$((m_ref - 43200))"
    done 3< "$TMP_DIR/noon" 4< "$TMP_DIR/periods" \
        5< "$TMP_DIR/months" > "$2"
}

# Monthly bound of a run made on each day of a list: the bound block above,
# expression for expression, the day of the run standing for today. Reads
# the days from "$1", writes one MONTHLY_UNIX per line to "$2".
bound_days() {
    "$SED_BIN" 's/$/ 12:00/' "$1" |
        "$DATE_BIN" -f - '+%-d %Y-%m-15' > "$TMP_DIR/b_today"
    while read -r _ b_ym; do
        printf '%s 12:00 %s months ago\n' "$b_ym" "$MONTHLY"
    done < "$TMP_DIR/b_today" | "$DATE_BIN" -f - +%Y-%m > "$TMP_DIR/b_ym"
    "$SED_BIN" 's/$/-15 12:00 1 month/' "$TMP_DIR/b_ym" |
        "$DATE_BIN" -f - +%Y-%m-01 | "$SED_BIN" 's/$/ 12:00 1 day ago/' |
        "$DATE_BIN" -f - +%-d > "$TMP_DIR/b_last"
    while read -r b_day _ <&3 && read -r b_ym <&4 && read -r b_last <&5; do
        if [ "$b_day" -gt "$b_last" ]; then
            b_day=$b_last
        fi
        printf '%s-%s 12:00\n' "$b_ym" "$b_day"
    done 3< "$TMP_DIR/b_today" 4< "$TMP_DIR/b_ym" 5< "$TMP_DIR/b_last" |
        "$DATE_BIN" -f - +%s > "$TMP_DIR/b_noon"
    while read -r b_unix; do
        printf '%s\n' "$((b_unix - WEEKLY_SEC))"
    done < "$TMP_DIR/b_noon" > "$2"
}

# One run of tarsnap-backup.sh, at NOW_UNIX and with MONTHLY_UNIX already
# set: decide() on every archive of the set "$1", whose lines read "name
# f_unix w_key w_unix m_key m_unix", oldest first. The kept lines go to
# "$2", the names of the deleted archives to "$3", their number to
# NIGHT_DEL.
run_night() {
    SEEN_WEEKS=" "
    SEEN_MONTHS=" "
    NIGHT_DEL=0
    while read -r p_name f_unix w_key w_unix m_key m_unix; do
        p_line="$p_name $f_unix $w_key $w_unix $m_key $m_unix"
        decide
        if [ "$DECISION" = purge ]; then
            NIGHT_DEL=$((NIGHT_DEL + 1))
            printf '%s\n' "$p_name" >&7
        else
            printf '%s\n' "$p_line" >&6
        fi
    done < "$1" 6> "$2" 7> "$3"
}

# Projects runs of tarsnap-backup.sh, night after night, from the set "$1":
# a run decides the set as the backup would, its deleted archives leave
# the set, and the archive of the night joins it, which no run deletes the
# night it is made. A night past MAX_PURGE is reported with its archives,
# then counted as purged once with --force-purge, so that each burst shows
# on its own. $2: first night, YYYY-MM-DD; $3: number of nights; $4: time
# of the runs, HH:MM:SS; $5 and $6: what comes before and after the day in
# the names of the new archives. Sets P_MAX, the most archives deleted by
# one of the other nights, and P_OVER, the number of nights past
# MAX_PURGE. NOW_UNIX and MONTHLY_UNIX are restored on return.
project() {
    p_now0=$NOW_UNIX
    p_bound0=$MONTHLY_UNIX
    i=0
    while [ "$i" -lt "$3" ]; do
        printf '+%s days %s 12:00\n' "$i" "$2"
        i=$((i + 1))
    done | "$DATE_BIN" -f - +%F > "$TMP_DIR/p_days"
    "$SED_BIN" "s/\$/ $4/" "$TMP_DIR/p_days" |
        "$DATE_BIN" -f - +%s > "$TMP_DIR/p_now"
    bound_days "$TMP_DIR/p_days" "$TMP_DIR/p_bound"
    date_days "$TMP_DIR/p_days" "$TMP_DIR/p_new"
    "$CAT_BIN" "$1" > "$TMP_DIR/p_set"
    P_MAX=0
    P_OVER=0
    while IFS= read -r p_day <&3 && read -r NOW_UNIX <&4 &&
        read -r MONTHLY_UNIX <&5 && IFS= read -r p_new <&8; do
        run_night "$TMP_DIR/p_set" "$TMP_DIR/p_kept" "$TMP_DIR/p_del"
        if [ "$NIGHT_DEL" -gt "$MAX_PURGE" ]; then
            P_OVER=$((P_OVER + 1))
            printf '  %s  %s archives to delete, more than MAX_PURGE=%s\n' \
                "$p_day" "$NIGHT_DEL" "$MAX_PURGE"
            while IFS= read -r p_name; do
                printf '              %s\n' "$p_name"
            done < "$TMP_DIR/p_del"
        elif [ "$NIGHT_DEL" -gt "$P_MAX" ]; then
            P_MAX=$NIGHT_DEL
        fi
        "$CAT_BIN" "$TMP_DIR/p_kept" > "$TMP_DIR/p_set"
        printf '%s%s%s %s\n' "$5" "$p_day" "$6" "$p_new" >> "$TMP_DIR/p_set"
    done 3< "$TMP_DIR/p_days" 4< "$TMP_DIR/p_now" 5< "$TMP_DIR/p_bound" \
        8< "$TMP_DIR/p_new"
    NOW_UNIX=$p_now0
    MONTHLY_UNIX=$p_bound0
}

kd=0; kw=0; km=0; del=0; skip=0

# Weeks and months already represented, as " key key ... ": in both modes
# the archives come in chronological order, so that the first archive of
# each period is the one kept.
SEEN_WEEKS=" "
SEEN_MONTHS=" "

if [ -n "$LISTFILE" ]; then
    ###########################################################################
    # REPLAY MODE against a real list
    ###########################################################################
    if [ -n "$OPT_HOST" ]; then
        COMPUTER=$OPT_HOST
    else
        COMPUTER=$("$UNAME_BIN" -n)
    fi
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
    # longest name of the list as shown() prints it, so that a long
    # snapshot name does not shift the verdicts.
    NAME_WIDTH=32
    while IFS= read -r archive; do
        _shown=$(shown "$archive")
        if [ "${#_shown}" -gt "$NAME_WIDTH" ]; then
            NAME_WIDTH=${#_shown}
        fi
    done < "$TMP"

    printf 'Replay against the real list, hostname "%s":\n\n' "$COMPUTER"

    : > "$TMP_DIR/dated"
    NEWEST=""
    NEWEST_UNIX=0

    # One archive per line, read whole, as in tarsnap-backup.sh: blanks at
    # either end belong to the name and keep it outside the pattern, where
    # they used to be trimmed and the name decided as a regular one
    # (N-R1-11).
    while IFS= read -r archive; do
        # Empty line: the account holds no archive at all.
        [ -n "$archive" ] || continue
        # shellcheck disable=SC2254
        case "$archive" in
            *.part)
                print_verdict "$archive" "PARTIAL, left in place"
                skip=$((skip + 1)); continue ;;
            "${COMPUTER}-"$STAMP_GLOB)
                ;;
            *)
                print_verdict "$archive" "outside the pattern, untouchable"
                skip=$((skip + 1)); continue ;;
        esac

        stamp=${archive#"${COMPUTER}-"}
        day=${stamp%%_*}

        # Same date expressions as tarsnap-backup.sh, archive by archive:
        # noon of the day, whose midnight is taken as noon minus 12 hours,
        # since a change to summer time can skip midnight itself (N-R1-13).
        # A date that does not exist is kept by the backup with a warning:
        # it gets a verdict of its own here, and no longer stops the replay
        # (TB-04, RC-04). The relative item comes first: placed after a
        # time, "-N" would be read as a time zone offset.
        if ! f_noon=$("$DATE_BIN" -d "$day 12:00" +%s 2>/dev/null); then
            print_verdict "$archive" "impossible date, kept"
            skip=$((skip + 1)); continue
        fi
        f_unix=$((f_noon - 43200))
        f_dow=$("$DATE_BIN" -d "$day 12:00" +%w)
        w_back=$(( (f_dow - DOW + 7) % 7 ))
        w_ref=$("$DATE_BIN" -d "-$w_back days $day 12:00" '+%F %s')
        w_key=${w_ref% *}
        w_unix=$((${w_ref#* } - 43200))
        m_key=$("$DATE_BIN" -d "-$((DOM - 1)) days $day 12:00" +%Y-%m)
        m_ref=$("$DATE_BIN" -d "+$((DOM - 1)) days ${m_key}-01 12:00" +%s)
        m_unix=$((m_ref - 43200))
        # Kept for the projection of the nights to come, before decide()
        # drops the month of an archive older than the monthly bound. The
        # list being sorted, the last one is the newest.
        printf '%s %s %s %s %s %s\n' "$archive" "$f_unix" "$w_key" \
            "$w_unix" "$m_key" "$m_unix" >> "$TMP_DIR/dated"
        NEWEST=$archive
        NEWEST_UNIX=$f_unix
        decide

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

    # The dates of the whole history come from date_days(), in a few calls
    # to date, with the expressions of the replay and of tarsnap-backup.sh,
    # and the decision is the same function.
    #
    # The days of the history come oldest first, as the backup sees them
    # after its sort, and are counted from noon of today: "-N days" from
    # now kept the summer or winter time of the moment, so that a run in
    # the hour after midnight shifted a whole season by one day
    # (N-GAP2-6). The archive of the run itself, which tarsnap-backup.sh
    # never purges in the same run (N-R1-12), needs no special case: the
    # archive of the day always falls into the son tier, DAILY being at
    # least 1.
    TODAY=$("$DATE_BIN" +%F)
    i=$DAYS
    while [ "$i" -gt 0 ]; do
        i=$((i - 1))
        printf '%s 12:00 %s days ago\n' "$TODAY" "$i"
    done | "$DATE_BIN" -f - +%F > "$TMP_DIR/days"
    date_days "$TMP_DIR/days" "$TMP_DIR/dated"

    # The archives kept make the steady state, which the breaker checks
    # below start from: what the rotation keeps when it runs every night.
    while IFS= read -r day <&3 &&
        read -r f_unix w_key w_unix m_key m_unix <&4; do
        s_line="$day $f_unix $w_key $w_unix $m_key $m_unix"
        decide
        case "$DECISION" in
            son)     kd=$((kd + 1)) ;;
            father)  kw=$((kw + 1)) ;;
            gfather) km=$((km + 1)) ;;
            *)       del=$((del + 1)) ;;
        esac
        if [ "$DECISION" != purge ]; then
            printf '%s\n' "$s_line" >&6
        fi
    done 3< "$TMP_DIR/days" 4< "$TMP_DIR/dated" 6> "$TMP_DIR/steady"
    printf '\n'
fi

printf '  son         (daily)    : %s\n' "$kd"
printf '  father      (weekly)   : %s\n' "$kw"
printf '  grandfather (monthly)  : %s\n' "$km"
printf '  deleted                : %s\n' "$del"
[ "$skip" -gt 0 ] && printf '  outside the rotation   : %s\n' "$skip"
printf '  ----------------------------------\n'
printf '  kept in total          : %s\n\n' "$((kd + kw + km))"

if [ -n "$LISTFILE" ]; then
    # Replay: a recent machine keeps nothing in the upper tiers yet, which
    # says nothing about its configuration. Only a weekly tier that the
    # configuration disables is pointed out.
    if [ "$kw" -eq 0 ] && [ "$ANOMALIE" -eq 1 ]; then
        printf 'CONCLUSION: the father tier keeps nothing.\n'
    fi
    # A run at this very moment would delete the archives marked DELETED
    # above. Past MAX_PURGE, the breaker of tarsnap-backup.sh stops it: the
    # run deletes nothing and ends with an error.
    if [ "$del" -gt "$MAX_PURGE" ]; then
        printf 'CONCLUSION: a run now would delete %s archives, more than\n' \
            "$del"
        printf '  MAX_PURGE=%s: it would stop and delete nothing, unless\n' \
            "$MAX_PURGE"
        printf '  given --force-purge.\n'
    fi

    if [ -n "$NEWEST" ]; then
        TODAY=$("$DATE_BIN" +%F)
        TODAY_UNIX=$(($("$DATE_BIN" -d "$TODAY 12:00" +%s) - 43200))
        # The clock, and the cron. An archive dated after today comes from
        # a clock ahead, here or on the machine that made it: the breaker
        # exists for such a clock (N-R1-6). A newest archive two days old
        # or more tells of missed nights, whose rotation the next run
        # applies at once (N-R2-3). Day counts at noon, as decide() does.
        if [ "$NEWEST_UNIX" -gt "$TODAY_UNIX" ]; then
            printf 'WARNING: the newest archive, %s, is dated after today:\n' \
                "$NEWEST"
            printf '  check the clocks, here and where it was made.\n'
        else
            GAP=$(( (TODAY_UNIX - NEWEST_UNIX + 43200) / 86400 ))
            if [ "$GAP" -ge 2 ]; then
                printf 'WARNING: the newest archive, %s, is %s days old:\n' \
                    "$NEWEST" "$GAP"
                printf '  the next run applies the missed nights at once.\n'
            fi
        fi

        # The nights to come, from the next run at the time of day of the
        # newest archive, which is the time cron runs the backup.
        # Assumptions, as tarsnap-backup.sh would meet them: one run a
        # night, no manual run, the same configuration. By default, the
        # projection lasts until every archive of the list has left the
        # daily window, where the bursts come from: archives made the same
        # day leave it together.
        RUN_STAMP=${NEWEST##*_}
        RUN_TIME=$(printf '%s\n' "$RUN_STAMP" | "$SED_BIN" 's/-/:/g')
        FIRST=$TODAY
        RUN_UNIX=$("$DATE_BIN" -d "$TODAY $RUN_TIME" +%s)
        if [ "$RUN_UNIX" -le "$NOW_UNIX" ]; then
            FIRST=$("$DATE_BIN" -d "+1 days $TODAY 12:00" +%F)
        fi
        if [ "$DAYS_SET" -eq 1 ]; then
            NIGHTS=$DAYS
        else
            NIGHTS=$((DAILY + 1))
        fi
        printf '\nNext %s nights, one run a night at %s, from %s:\n' \
            "$NIGHTS" "$RUN_TIME" "$FIRST"
        project "$TMP_DIR/dated" "$FIRST" "$NIGHTS" "$RUN_TIME" \
            "${COMPUTER}-" "_$RUN_STAMP"
        if [ "$P_OVER" -eq 0 ]; then
            printf '  no night deletes more than MAX_PURGE=%s, at most %s.\n' \
                "$MAX_PURGE" "$P_MAX"
        else
            printf '  the other nights delete at most %s. Each night above\n' \
                "$P_MAX"
            printf '  is counted as purged once, with --force-purge.\n'
        fi
    fi
else
    # Simulation: the verdict rests on what each tier actually kept, and no
    # longer on the configuration alone, which printed "consistent" with
    # empty tiers (RC-01). The son tier always keeps the archive of the
    # day, DAILY being at least 1. A tier that the simulated history does
    # not reach is not blamed on the configuration.
    if [ "$ANOMALIE" -eq 0 ] && [ "$kd" -gt 0 ] && [ "$kw" -gt 0 ] &&
        [ "$km" -gt 0 ]; then
        printf 'All three tiers are active, the configuration is consistent.\n'
    fi
    if [ "$kw" -eq 0 ]; then
        printf 'CONCLUSION: the father tier keeps nothing.\n'
        if [ "$DAYS" -le "$DAILY" ]; then
            printf '  %s simulated days do not reach its window, see -D.\n' \
                "$DAYS"
        fi
    fi
    if [ "$km" -eq 0 ]; then
        printf 'CONCLUSION: the grandfather tier keeps nothing.\n'
        if [ "$DAYS" -le "$((WEEKLY_SEC / 86400))" ]; then
            printf '  %s simulated days do not reach its window, see -D.\n' \
                "$DAYS"
        fi
    fi

    # The breaker, MAX_PURGE, against the steady state, the archives kept
    # above. A normal night first: the next nights, one run each at the
    # time of day of now. Then a gap between two runs, from missed nights
    # or from a clock ahead, which both make a run see the same archives
    # older, by as many days (N-R2-3, N-R1-6). Last, when options change
    # the retention values, the first run after the values of the file
    # gave way to them, as for a reinstalled script whose retention went
    # back to the defaults (N-R2-1).
    printf '\nPurge circuit breaker, MAX_PURGE=%s:\n' "$MAX_PURGE"
    RUN_TIME=$("$DATE_BIN" +%T)
    FIRST=$("$DATE_BIN" -d "+1 days $TODAY 12:00" +%F)
    project "$TMP_DIR/steady" "$FIRST" 62 "$RUN_TIME" "" ""
    if [ "$P_OVER" -eq 0 ]; then
        printf '  a normal night deletes at most %s, over 62 nights.\n' \
            "$P_MAX"
    else
        printf '  the other normal nights delete at most %s.\n' "$P_MAX"
    fi

    STEADY=$((kd + kw + km))
    if [ "$MAX_PURGE" -ge "$STEADY" ]; then
        printf '  no gap between two runs can trip it: %s are kept.\n' \
            "$STEADY"
    else
        # A run g_k days after the last one, ten years at most: past the
        # monthly window, the rotation deletes every archive kept, more
        # than MAX_PURGE.
        i=1
        while [ "$i" -le 3660 ]; do
            printf '+%s days %s 12:00\n' "$i" "$TODAY"
            i=$((i + 1))
        done | "$DATE_BIN" -f - +%F > "$TMP_DIR/g_days"
        "$SED_BIN" "s/\$/ $RUN_TIME/" "$TMP_DIR/g_days" |
            "$DATE_BIN" -f - +%s > "$TMP_DIR/g_now"
        bound_days "$TMP_DIR/g_days" "$TMP_DIR/g_bound"
        s_now0=$NOW_UNIX
        s_bound0=$MONTHLY_UNIX
        g_k=0
        g_prev=0
        NIGHT_DEL=0
        while read -r NOW_UNIX <&3 && read -r MONTHLY_UNIX <&4; do
            g_k=$((g_k + 1))
            run_night "$TMP_DIR/steady" "$TMP_DIR/g_kept" "$TMP_DIR/g_del"
            if [ "$NIGHT_DEL" -gt "$MAX_PURGE" ]; then
                break
            fi
            g_prev=$NIGHT_DEL
        done 3< "$TMP_DIR/g_now" 4< "$TMP_DIR/g_bound"
        NOW_UNIX=$s_now0
        MONTHLY_UNIX=$s_bound0
        if [ "$NIGHT_DEL" -le "$MAX_PURGE" ]; then
            printf '  no gap of up to ten years between two runs trips it.\n'
        elif [ "$g_k" -eq 1 ]; then
            printf '  even the next normal run trips it: it deletes %s.\n' \
                "$NIGHT_DEL"
        else
            printf '  it trips after %s missed night(s) in a row, or with a\n' \
                "$((g_k - 1))"
            printf '  clock %s day(s) ahead, deleting %s (%s a day less).\n' \
                "$((g_k - 1))" "$NIGHT_DEL" "$g_prev"
        fi
    fi

    if [ "$DAILY" != "$FILE_DAILY" ] || [ "$WEEKLY" != "$FILE_WEEKLY" ] ||
        [ "$MONTHLY" != "$FILE_MONTHLY" ] || [ "$DOW" != "$FILE_DOW" ] ||
        [ "$DOM" != "$FILE_DOM" ]; then
        # The steady state of the values of the file, over the same
        # history, then its archives dated and decided with the values
        # given, at the same moment: the first run after the change.
        e_daily=$DAILY; e_weekly=$WEEKLY; e_monthly=$MONTHLY
        e_dow=$DOW; e_dom=$DOM
        e_dsec=$DAILY_SEC; e_wsec=$WEEKLY_SEC; e_bound=$MONTHLY_UNIX
        DAILY=$FILE_DAILY; WEEKLY=$FILE_WEEKLY; MONTHLY=$FILE_MONTHLY
        DOW=$FILE_DOW; DOM=$FILE_DOM
        DAILY_SEC=$((DAILY * 86400))
        WEEKLY_SEC=$((DAILY_SEC + WEEKLY * 604800))
        printf '%s\n' "$TODAY" > "$TMP_DIR/x_today"
        bound_days "$TMP_DIR/x_today" "$TMP_DIR/x_bound"
        read -r MONTHLY_UNIX < "$TMP_DIR/x_bound"
        date_days "$TMP_DIR/days" "$TMP_DIR/x_dated"
        SEEN_WEEKS=" "
        SEEN_MONTHS=" "
        while IFS= read -r day <&3 &&
            read -r f_unix w_key w_unix m_key m_unix <&4; do
            decide
            if [ "$DECISION" != purge ]; then
                printf '%s\n' "$day" >&6
            fi
        done 3< "$TMP_DIR/days" 4< "$TMP_DIR/x_dated" 6> "$TMP_DIR/x_days"

        DAILY=$e_daily; WEEKLY=$e_weekly; MONTHLY=$e_monthly
        DOW=$e_dow; DOM=$e_dom
        DAILY_SEC=$e_dsec; WEEKLY_SEC=$e_wsec; MONTHLY_UNIX=$e_bound
        date_days "$TMP_DIR/x_days" "$TMP_DIR/x_dated"
        while IFS= read -r day <&3 && IFS= read -r x_vals <&4; do
            printf '%s %s\n' "$day" "$x_vals"
        done 3< "$TMP_DIR/x_days" 4< "$TMP_DIR/x_dated" > "$TMP_DIR/x_set"
        run_night "$TMP_DIR/x_set" "$TMP_DIR/x_kept" "$TMP_DIR/x_del"
        printf '  from the values of %s to these,\n' "$BACKUP_SCRIPT"
        if [ "$NIGHT_DEL" -gt "$MAX_PURGE" ]; then
            printf '  the first run would delete %s: it trips.\n' \
                "$NIGHT_DEL"
        else
            printf '  the first run would delete %s, within MAX_PURGE.\n' \
                "$NIGHT_DEL"
        fi
    fi
fi
exit 0
