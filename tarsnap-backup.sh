#!/bin/sh
#
# tarsnap-backup.sh
#
# Grandfather / father / son rotation: a classic retention scheme, inherited
# from magnetic tape rotation, reimplemented here in POSIX sh.
#
# Deliberate order: the new archive is created BEFORE anything is destroyed.
# If tarsnap fails (network, quota, key), set -e aborts the script and no
# archive is deleted. The worst case is therefore "old archives pile up",
# never the behaviour: "I purged and I have nothing new".
#
# Options:
#   -n, -d, --dry-run      create no archive and delete nothing
#   -v, --verbose          detail the decision made for each archive
#   -s, --snapshot-name N  create a named archive, outside the rotation
#   -o, --orphans          list the archives beyond the reach of the rotation
#   -h, --help             display the help
#
# The tarsnap man page forbids two concurrent create or delete operations
# with the same key: the script therefore takes a lock of its own.
#

# -e: exit on the first error
# -u: an unset variable is an error
# -f: no globbing on unquoted expansions ($BACKUP_DIRS, exclusion
#     patterns).

set -euf

#################
# CONFIGURATION #
#################

# --- Absolute paths of the binaries ---
#
# The paths are hardcoded so as not to depend on the caller's $PATH, be it
# cron, systemd or a misconfigured sudo. They are given for Debian with
# usrmerge, hence everything under /usr/bin.
#
TARSNAP_BIN="/usr/bin/tarsnap"
DATE_BIN="/usr/bin/date"
UNAME_BIN="/usr/bin/uname"
LOCALE_BIN="/usr/bin/locale"
GREP_BIN="/usr/bin/grep"
SED_BIN="/usr/bin/sed"
SORT_BIN="/usr/bin/sort"
DPKG_BIN="/usr/bin/dpkg"
APT_BIN="/usr/bin/apt"
FLOCK_BIN="/usr/bin/flock"

# --- Default behaviour, can be overridden by the options ---
DRY=0            # 1 = full simulation, no archive is created or deleted
VERBOSE=0        # 1 = detail each decision and pass -v to tarsnap
SNAPSHOT_NAME="" # non-empty = named archive, outside the rotation
ORPHANS=0        # 1 = list the archives outside the rotation, then exit

# --- Tarsnap ---
# Path of the Tarsnap private key.
# Leave empty to rely on the keyfile declared in tarsnap.conf.
# No whitespace allowed.
TARSNAP_KEY="/root/tarsnap.key"

# Passphrase entry method for a protected key, passed to tarsnap as
# --passphrase (tarsnap 1.0.40 or later). Leave empty for the default
# behaviour: tarsnap asks on the terminal, which cron does not have.
#   dev:tty-stdin   /dev/tty, otherwise stdin (the default of tarsnap)
#   dev:tty-once    /dev/tty only
#   dev:stdin-once  stdin only
#   env:NAME        environment variable NAME, which cron must provide;
#                   pick a name of your own, not a variable of this script
#   file:PATH       a single line, the passphrase; keep the file in 0600
# Only env: and file: work without a terminal. On the command line, the
# method takes precedence over a "passphrase" line of tarsnap.conf, which
# tarsnap then silently ignores. No whitespace allowed.
TARSNAP_PASSPHRASE=""

# Directories to back up, space-separated absolute paths. A trailing slash
# is removed; a relative path, "//", a "." or ".." component and a
# symbolic link are refused, see check_dirs(). A missing directory is not
# refused: tarsnap reports it, and the run then ends with exit status 2.
BACKUP_DIRS="/root /boot /etc"

# Exclusion patterns, space-separated. Two forms are accepted:
#   - glob pattern ("*/tmp/*"), passed as is to tarsnap
#   - absolute path ("/var/www/html/APOD"), also passed as is: tarsnap
#     compares a pattern starting with / with the full path, so that it is
#     anchored at the root and excludes that path only.
# A trailing slash is removed, and a pattern made of / alone is refused,
# see check_excludes().
BACKUP_EXCLUDE="*/tmp/* /var/www/html/APOD"

# Run lock. In /run, and neither in /tmp nor in /run/lock, which are mode
# 1777: any local user could hold the lock there and block the backups.
# /run is mode 755, owned by root.
LOCK_FILE="/run/tarsnap-backup.lock"

# Package inventory, regenerated before each backup
PKG_SELECTIONS="/root/pkg-selections.txt"
PKG_LIST="/root/pkg-list.txt"

# --- Retention: grandfather / father / son scheme ---
# The three windows are CUMULATIVE: they follow one another instead of
# overlapping. Each tier takes over where the previous one stops, and the
# total coverage is therefore DAILY days + WEEKLY weeks + MONTHLY months.
# The weekly and monthly tiers keep the first archive of each week, which
# starts on DOW, and of each month, which starts on DOM: when the night of
# DOW or DOM is missed, the next archive of the period stands in for it.
DAILY=90    # everything is kept over the first N days
WEEKLY=12   # then, over the next N weeks, the first archive of each week
MONTHLY=48  # then, over the next N months, the first archive of each month
DOW=1       # first day of the weeks (0 = Sunday, 1 = Monday)
DOM=1       # first day of the months, from 1 to 31

# --- Purge circuit breaker ---
# Most archives a single run may delete. Past it, the run deletes nothing,
# keeps the archive it has just created, and stops with an error, hence a
# cron mail: review with --dry-run --verbose, then rerun once with
# --force-purge. In steady state a run deletes 0 or 1 archive, and a clock
# moved forward makes the purge delete about one archive per day of shift:
# 7 lets a week of missed nights through, and stops a clock that jumped
# more than about a week ahead, retention values cut by mistake, or a
# reinstalled script whose retention went back to the defaults.
# Decimal integer from 1 to 99999, without a leading zero.
MAX_PURGE=7

###############################################################################
# END OF CONFIGURATION
###############################################################################

# Function declarations

# Exit code as argument: 0 for --help, 1 for an invalid option.
usage() {
    cat >&2 <<EOF
usage: ${0##*/} [-d|-n|--dry-run] [-v|--verbose] [-F|--force-purge]
       ${0##*/} [-s|--snapshot-name] NAME
       ${0##*/} [-o|--orphans]
       ${0##*/} [-h|--help]

  -d, -n, --dry-run      full simulation: nothing is created or deleted,
                         only the purge command is printed. The creation
                         is simulated by tarsnap --dry-run, which reads the
                         files, so it takes as long as a real run.
  -v, --verbose          detail the decision made for each archive
  -F, --force-purge      lift MAX_PURGE for this run only, once the purge
                         has been reviewed with --dry-run --verbose
  -s, --snapshot-name N  create an archive suffixed with N, then exit
                         without rotating. Its name makes it permanently
                         untouchable by the purge. Also accepts
                         --snapshot-name=N.
  -o, --orphans          list the archives beyond the reach of the
                         rotation, orphaned and partial, then exit without
                         backing up or deleting anything. Read-only.
  -h, --help             display this help
EOF
    exit "${1:-1}"
}

# Print only in verbose mode.
# printf and not echo: the behaviour of echo on a backslash or on an
# argument starting with "-" is not specified by POSIX, and dash
# interprets escape sequences where bash does not.
# The "return 0" is essential: without it, a false [ ] would make the
# script exit because of set -e.
say() {
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"
    return 0
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# prebackup: everything that must be prepared before tarsnap reads the
# files. Inventories, database dumps, configuration export, call to an
# external script.
#
# WARNING: prebackup is ALSO run in --dry-run, and this is intentional. A
# simulation that did not prepare the same files would not simulate much.
# Practical consequence: if you put a dump of several gigabytes in it,
# comment it out before running trial after trial, otherwise every
# --dry-run replays it in full.
#
# The function must return 0. Any other value stops the script BEFORE the
# archive is created, hence before any deletion: better to back up nothing
# than to back up a half-dumped database.
#
# set -e only stops the script on a command that fails on a line of its
# own. A failure goes unnoticed in a pipeline, except in its last command
# (dash has no pipefail), on the left of && or ||, and in the condition of
# an if or a while: one command per line, and test what has to be tested.
#
# Both hooks run in a subshell, see run_hook(): a variable they set does
# not reach the rest of the script.
prebackup() {
    say "Taking inventory of installed packages."
    "$DPKG_BIN" --get-selections > "$PKG_SELECTIONS"
    # apt warns on stderr, at every call, that its interface is not stable:
    # the message is captured, and only shown when apt fails. The failure
    # does not stop the backup, the rest of the system being worth more
    # than a list of packages, but it is reported with apt's own message.
    if ! _apt_err=$("$APT_BIN" list --installed 2>&1 >"$PKG_LIST"); then
        printf 'WARNING: apt list failed, incomplete list in %s:\n' \
            "$PKG_LIST" >&2
        printf '%s\n' "$_apt_err" >&2
    fi

    # Examples to uncomment and adapt. Declare the absolute path of the
    # binary at the top of the script, like the others, rather than
    # relying on $PATH.
    #
    # MySQL / MariaDB dump. The credentials go in ~/.my.cnf with mode 0600,
    # never on the command line, where ps would make them visible to all.
    # say "Dumping the MySQL databases."
    # /usr/bin/mysqldump --all-databases --single-transaction --quick \
    #     --events --routines > /root/dumps/mysql-all.sql
    #
    # PostgreSQL dump.
    # say "Dumping the PostgreSQL databases."
    # su - postgres -c /usr/bin/pg_dumpall > /root/dumps/postgres-all.sql
    #
    # Partition table, to be able to start again from a bare disk.
    # /usr/sbin/sfdisk --dump /dev/sda > /root/partitions-sda.txt
    #
    # External script. Its failure propagates up to here and stops the
    # backup.
    # /usr/local/sbin/pre-backup-hook.sh

    return 0
}

# postbackup: the counterpart of prebackup, run once the archive has been
# created, snapshot included, and before the rotation. Cleanup of the
# temporary dumps, notification, restart of a service stopped by prebackup.
#
# Same rules: it is also run in --dry-run, and it must return 0. A failure
# here leaves the archive in place and skips the rotation, so the old
# archives pile up. That is the desirable way to fail.
#
# It receives the exit status of tarsnap -c as $1: 0 on success, 2 when the
# archive was created but some files could not be read, any other value
# when the creation failed. It runs in every case, so that whatever
# prebackup set up is undone; on a failed creation the script then stops
# without touching the rotation.
postbackup() {
    # say "Cleaning up the dumps."
    # rm -f /root/dumps/mysql-all.sql
    #
    # say "Sending the notification."
    # /usr/local/sbin/post-backup-hook.sh

    return 0
}

# Runs a hook, prebackup or postbackup, in a subshell. The hooks are the
# user's code, which would otherwise inherit the internals of the script:
#   - descriptor 9, which holds the lock: a daemon started by a hook would
#     keep it open, and every following run would find the lock taken;
#   - the variable named by an env: passphrase, which every program started
#     by a hook would receive in its environment;
#   - the -f option, which disables globbing: "rm -f /root/dumps/*.sql"
#     would remove nothing.
# set -e remains active in the subshell, and a failure in the hook stops
# the script. The calls stay bare, never in a condition, see STEP 1.
run_hook() {
    (
        exec 9>&-
        case "$TARSNAP_PASSPHRASE" in
            env:*) unset "${TARSNAP_PASSPHRASE#env:}" ;;
        esac
        set +f
        case "$1" in
            prebackup) prebackup ;;
            postbackup) postbackup "$2" ;;
        esac
    )
}

# Print one family of archives, then the matching delete command. Nothing
# is deleted: the command is only printed, to be reviewed and then pasted
# by hand.
orphans_section() {
    _title=$1
    _list=$2

    printf -- '--- %s ---\n' "$_title"
    if [ -z "$_list" ]; then
        printf '  (none)\n\n'
        return 0
    fi
    for _a in $_list; do
        printf '  %s\n' "$_a"
    done
    printf '\n  Delete command, review before pasting:\n'
    if [ -n "$TARSNAP_KEYOPT" ]; then
        printf '  %s %s -d' "$TARSNAP_BIN" "$TARSNAP_KEYOPT"
    else
        printf '  %s -d' "$TARSNAP_BIN"
    fi
    for _a in $_list; do
        printf -- ' -f %s' "$_a"
    done
    printf '\n\n'
    return 0
}

# List the archives that the rotation will never touch. Read-only: no
# archive is created or deleted.
#
# Two families, for two distinct reasons.
#
# The orphans: their name does not match the pattern
# "hostname-YYYY-MM-DD_HH-MM-SS", so the purge does not even look at them.
# Snapshots created with -s, archives made by hand, archives from another
# machine sharing the same key, archives dating from a previous hostname.
#
# The partials: suffixed .part, leftovers of an interrupted run. tarsnap(1)
# gives two origins: an archive truncated on purpose, by ^Q, SIGQUIT or the
# --maxbw limit, and the last checkpoint of a run that died, which tarsnap
# recovers at the next creation or deletion. They count for deduplication
# and may contain data found nowhere else.
list_orphans() {
    say "Fetching the list of archives."
    # shellcheck disable=SC2086
    _all=$("$TARSNAP_BIN" $TARSNAP_KEYOPT --list-archives)

    _orphans=""
    _parts=""
    for _a in $_all; do
        # shellcheck disable=SC2254
        case "$_a" in
            *.part)
                _parts="${_parts} ${_a}" ;;
            "${COMPUTER}-"$STAMP_GLOB)
                ;;
            *)
                _orphans="${_orphans} ${_a}" ;;
        esac
    done

    printf 'Archives beyond the reach of the rotation, hostname "%s".\n\n' "$COMPUTER"
    orphans_section "Orphans: name outside the pattern, never purged" "$_orphans"
    orphans_section "Partials: truncated, or checkpoint recovered" "$_parts"
    return 0
}

# Passphrase-protected key. A text key file, once its comments and blank
# lines are skipped and its base64 decoded, starts with "scrypt" when it is
# encrypted and with "tarsnap\0" otherwise: this is the format described,
# and the very test made, in lib/keyfile/keyfile.c of tarsnap. In base64,
# "scrypt" gives exactly the first 8 characters of the first data line,
# "c2NyeXB0": no decoding needed. A raw binary key file (first byte 0x00
# or 0xff) is never encrypted: that byte is neither "#", nor a blank, nor
# "c", so the first line sed reads is the one tested, and it never
# matches, which is the verdict of keyfile_read().
#
# sed returns a verdict, the fixed word "scrypt" or nothing, never the line
# itself, so the NUL bytes of a raw key no longer reach the shell. They
# used to: bash warned "ignored null byte in input", into the cron mail,
# and both shells dropped them before the test. s/.*/scrypt/ would not do:
# in a UTF-8 locale, "." does not match an invalid byte such as 0xff, the
# rest of the line would still come out, and the locale here is the
# caller's. i\ writes its own text and nothing of the line. POSIX joins
# the -e pieces with newlines, which puts that text on its own line;
# SC1003 is a false alarm, the backslash belongs to i\ and escapes nothing
# in the shell. The errors of sed stay visible: an unreadable file shows its
# message and counts as not protected. POSIX only specifies sed on text
# files: a raw key relies on GNU sed, as it always has.
#
# Known limitation: keyfile.c also takes a lone CR as an end of line. sed
# then sees a single line, which starts with "# START OF TARSNAP KEY FILE"
# and is skipped as a comment: such a protected key is reported as not
# protected. tarsnap-keygen and tarsnap-keymgmt write LF, and CRLF is
# handled.
#
# Kept identical to the function of the same name in tarsnap-diff.sh.
key_is_passphrased() {
    # shellcheck disable=SC1003
    _verdict=$("$SED_BIN" -n -e '/^#/d; /^[[:space:]]*$/d' \
        -e '/^c2NyeXB0/i\' -e 'scrypt' -e 'q' "$1")
    case "$_verdict" in
        scrypt) return 0 ;;
    esac
    return 1
}

# Can tarsnap obtain the passphrase of a protected key, with the method of
# TARSNAP_PASSPHRASE? Mirrors tarsnap 1.0.41, method by method: readpass()
# of libcperciva reads /dev/tty then stdin for dev:tty-stdin (devtty 1),
# stdin only for dev:stdin-once (devtty 0) and /dev/tty only for
# dev:tty-once (devtty 2); env: calls getenv(); file: calls
# readpass_file(), which wants a single line and strips its CR or LF.
# An empty variable or file is refused as well: tarsnap would read an
# empty passphrase and fail on it, after prebackup. A file that is not a
# regular one (FIFO, device) is only checked for readability, so as not
# to consume it. Sets PASSPHRASE_HOW for the verbose message and
# PASSPHRASE_WHY for the error message. TARSNAP_PASSPHRASE has been
# validated beforehand: the eval only ever sees a valid variable name.
passphrase_reachable() {
    case "$TARSNAP_PASSPHRASE" in
        ""|dev:tty-stdin)
            PASSPHRASE_HOW="tarsnap will ask for it on each call"
            PASSPHRASE_WHY="no terminal to type the passphrase"
            ( exec </dev/tty ) 2>/dev/null || [ -t 0 ]
            ;;
        dev:tty-once)
            PASSPHRASE_HOW="tarsnap will ask for it on /dev/tty on each call"
            PASSPHRASE_WHY="dev:tty-once and no /dev/tty"
            ( exec </dev/tty ) 2>/dev/null
            ;;
        dev:stdin-once)
            PASSPHRASE_HOW="tarsnap will ask for it on stdin on each call"
            PASSPHRASE_WHY="dev:stdin-once and stdin is not a terminal"
            [ -t 0 ]
            ;;
        env:*)
            _pp_name=${TARSNAP_PASSPHRASE#env:}
            PASSPHRASE_HOW="read from the environment variable $_pp_name"
            PASSPHRASE_WHY="environment variable $_pp_name unset or empty"
            _pp_value=""
            eval "_pp_value=\${$_pp_name-}"
            [ -n "$_pp_value" ]
            ;;
        file:*)
            _pp_file=${TARSNAP_PASSPHRASE#file:}
            PASSPHRASE_HOW="read from $_pp_file"
            PASSPHRASE_WHY="passphrase file $_pp_file unreadable,"
            PASSPHRASE_WHY="$PASSPHRASE_WHY empty or not a single line"
            [ -r "$_pp_file" ] || return 1
            [ -f "$_pp_file" ] || return 0
            [ -s "$_pp_file" ] &&
                [ "$("$SED_BIN" -n '$=' "$_pp_file")" = 1 ]
            ;;
    esac
}

# Key designated by tarsnap.conf, for when TARSNAP_KEY is empty: tarsnap
# itself is asked. --dump-config alone switches tarsnap to its
# --verify-config mode, which exits before loading the key (tarsnap 1.0.41,
# tar/bsdtar.c), so without a passphrase prompt and without network access.
# It prints on stderr, in reading order, the command line, then a "Reading
# from config file:" header for each file tried, followed by the option
# lines of that file, leading blanks stripped, indented by two spaces. The
# first keyfile wins, hence the first "  keyfile" line after the first
# header. Prints that path, or prints nothing and returns 1 when the answer
# is not reliable: non-zero exit (tarsnap older than 1.0.40, invalid
# configuration), no keyfile line, an argument starting with "~" (tarsnap
# expands it with the home directory of the password database, not $HOME,
# and this script does not read that database), or an argument containing
# a blank (kept by tarsnap, with a warning).
conf_keyfile() {
    _ck_dump=$("$TARSNAP_BIN" --dump-config 2>&1 >/dev/null) || return 1
    _ck_key=$(printf '%s\n' "$_ck_dump" | "$SED_BIN" -n \
        -e '1,/^Reading from config file: /d' \
        -e '/^  keyfile[[:space:]]/!d' \
        -e 's/^  keyfile[[:space:]]*//p' -e 'q')
    case "$_ck_key" in
        ""|"~"*|*[[:space:]]*) return 1 ;;
    esac
    printf '%s\n' "$_ck_key"
}

# Retention values. Each one must be a decimal integer written without a
# leading zero: the arithmetic of dash and bash reads "030" as octal, so
# DAILY=030 silently kept 24 days of daily archives instead of 30 and
# WEEKLY=012 ten weeks, while "090" stopped the script with a message that
# depends on the shell. A negative value, a word ("Mon"), a comment glued
# to the value ("1#Monday") or the CR of a configuration saved with DOS
# line endings ended in a silent over-purge, or in a purge that went on
# through a flood of error messages. An explicit list of digits rather
# than a range such as [0-9], whose content depends on the locale.
#
# Five digits at most, checked on the text before any comparison: with
# twenty digits, [ -lt ] and [ -gt ] fail ("Illegal number" under dash,
# "integer expression expected" under bash), the if turns false, and the
# value went through to an arithmetic that wraps around. Five digits keep
# the worst case, 99999 days plus 99999 weeks in seconds, at 69119308800,
# far from the 9223372036854775807 of 64-bit arithmetic, and date -d still
# takes 99999 months. No tighter bound per variable: a larger value only
# ever keeps more archives, never fewer, and DAILY=99999 remains a simple
# way to suspend the purge.
#
# Then the ranges: DAILY of at least 1, so that the archive this very run
# creates never falls outside the daily window and into its own purge; DOW
# from 0 (Sunday) to 6 (Saturday), as date +%w counts, so that the 7 that
# cron accepts for Sunday is refused, date +%w never giving it; DOM from
# 1 to 31. WEEKLY or MONTHLY at 0 disables its tier, as documented. The
# messages name the variable but never echo its raw value. To be kept
# identical, byte for byte, to the function of the same name in
# rotation-check.sh.
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

# Normalises BACKUP_DIRS in place. The trailing slashes are removed, then
# every entry that tarsnap would store under another name than its
# canonical path is refused: a relative path, "//", a "." or ".."
# component. Under such a name an absolute exclusion no longer matches,
# and a restore by the canonical path finds nothing. A symbolic link is
# refused as well: tarsnap would archive the link alone, and nothing of
# what it points to. A missing directory is not refused.
# Identical in tarsnap-backup.sh and tarsnap-diff.sh, see HACKING.md.
check_dirs() {
    _dirs=""
    for _d in $BACKUP_DIRS; do
        while :; do
            case "$_d" in
                ?*/) _d=${_d%/} ;;
                *) break ;;
            esac
        done
        case "$_d" in
            *//*|*/.|*/..|*/./*|*/../*)
                die "BACKUP_DIRS: non-canonical path (//, . or ..): $_d" ;;
            /*) ;;
            *)
                die "BACKUP_DIRS: not an absolute path: $_d" ;;
        esac
        if [ -L "$_d" ]; then
            die "BACKUP_DIRS: symbolic link, give the path it points to: $_d"
        fi
        _dirs="${_dirs:+$_dirs }$_d"
    done
    [ -n "$_dirs" ] || die "BACKUP_DIRS is empty"
    BACKUP_DIRS=$_dirs
}

# Normalises BACKUP_EXCLUDE in place. The trailing slashes are removed:
# tarsnap does the same, but tarsnap-diff.sh compares the patterns as they
# are written. A pattern made of / alone is refused: it would become "/*",
# which matches every entry of BACKUP_DIRS, and the archive would be empty
# without a message, --quiet hiding the warning tarsnap gives about it.
# Identical in tarsnap-backup.sh and tarsnap-diff.sh, see HACKING.md.
check_excludes() {
    _excl=""
    for _p in $BACKUP_EXCLUDE; do
        while :; do
            case "$_p" in
                ?*/) _p=${_p%/} ;;
                *) break ;;
            esac
        done
        if [ "$_p" = / ]; then
            die "BACKUP_EXCLUDE: the pattern / would exclude everything"
        fi
        _excl="${_excl:+$_excl }$_p"
    done
    BACKUP_EXCLUDE=$_excl
}

###############################################################################
# MAIN
###############################################################################

# The body of the script, from the option parsing to the end, is a single
# function, main(), called by the very last line of the file. The shell
# parses a function whole before running it, so the script can be edited,
# or overwritten in place by nano or cp, while a run is in progress. When
# the body ran as the shell read it, the shell went on reading the new
# content at the offset of the old one: bash rereads the script after
# every external command, dash reads it by blocks of 8 KiB, and fragments
# of lines, comments included, ran as root, postbackup was skipped, or the
# test of the monthly tier vanished and the purge took the monthly
# archives. The body is deliberately not indented, so that this change
# leaves its lines untouched. The configuration block and the functions
# stay outside: they are read in the first milliseconds of the run, and
# the companion tools read the configuration by "NAME=" at the start of a
# line.
main() {

# Set by -F or --force-purge, never in the configuration block: lifting
# the purge circuit breaker is a decision taken for one run, after review,
# not a setting.
FORCE_PURGE=0
SNAPSHOT_GIVEN=0

# POSIX getopts only knows single-character options: the long forms are
# translated before running it, with one or two dashes accepted.
for arg do
    shift
    case "$arg" in
        --help|-help)       usage 0 ;;
        --dry-run|-dry-run) set -- "$@" -d ;;
        --verbose|-verbose) set -- "$@" -v ;;
        # Attached form: we split on the first "=" ourselves.
        --snapshot-name=*|-snapshot-name=*)
                            set -- "$@" -s "${arg#*=}" ;;
        # Separate form: we only emit -s, the value follows in $@ and
        # getopts will pick it up, including to complain if it is missing.
        --snapshot-name|-snapshot-name)
                            set -- "$@" -s ;;
        --orphans|-orphans) set -- "$@" -o ;;
        --force-purge|-force-purge)
                            set -- "$@" -F ;;
        *)                  set -- "$@" "$arg" ;;
    esac
done

# Beware: the -d of the script means "delete nothing", the exact opposite
# of the -d of tarsnap, which does delete. -n is accepted as a synonym, it
# is the less ambiguous of the two forms.
while getopts "dFhnovs:" option; do
    case "$option" in
        d|n) DRY=1 ;;
        F) FORCE_PURGE=1 ;;
        h) usage 0 ;;
        o) ORPHANS=1 ;;
        s) SNAPSHOT_NAME=$OPTARG; SNAPSHOT_GIVEN=1 ;;
        v) VERBOSE=1 ;;
        *) usage 1 ;;
    esac
done

# getopts stops at the first operand and leaves it, with everything after
# it, in $@. The script takes none: an operand is a mistyped option, such
# as "dry-run" without its dashes, or a "--dry-run" pasted from a document
# whose dashes are typographic ones (U+2013, U+2014) rather than the ASCII
# hyphen-minus. Ignored, it used to turn a requested dry-run into a real
# backup followed by a real purge, without a word. Refused, with the help.
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
    printf 'ERROR: unexpected argument: %s\n' "$1" >&2
    printf '  options start with an ASCII "-", and a dash pasted from a\n' >&2
    printf '  document is not one\n' >&2
    usage 1
fi

###############################################################################
# SAFEGUARDS
###############################################################################

# All the configured binaries must be executable.
for bin in "$TARSNAP_BIN" "$DATE_BIN" "$UNAME_BIN" "$LOCALE_BIN" \
           "$GREP_BIN" "$SED_BIN" "$SORT_BIN" "$DPKG_BIN" "$APT_BIN" \
           "$FLOCK_BIN"; do
    [ -x "$bin" ] || die "binary missing or not executable: $bin"
done

# The snapshot name ends up in an archive name: anything that would
# introduce a space or an exotic character is forbidden. An explicit list
# rather than a range such as [A-Za-z], whose content depends on the locale.
#
# -s given an empty name would fall back to a normal backup, rotation
# included. A name starting with "-" is most likely an option swallowed by
# -s ("-s --dry-run"), which would then run for real.
if [ "$SNAPSHOT_GIVEN" -eq 1 ] && [ -z "$SNAPSHOT_NAME" ]; then
    die "empty snapshot name"
fi
case "$SNAPSHOT_NAME" in
    "") ;;
    -*)
        die "invalid snapshot name, it must not start with -" ;;
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
        die "invalid snapshot name, allowed characters: A-Z a-z 0-9 _ -" ;;
esac

# Retention values, see check_retention(). Checked in every mode, like the
# other safeguards: a broken value is reported by the next run of any
# kind, a snapshot or --orphans included, rather than discovered through
# a purge.
check_retention

# Directories and exclusion patterns, see check_dirs() and
# check_excludes(). Same reasoning: in every mode, and before prebackup.
check_dirs
check_excludes

# MAX_PURGE follows the rules of the retention values, from 1 to 99999: a
# decimal integer without a leading zero, five digits at most, checked on
# the text. 0 would stop every purge, which is the job of --dry-run, not
# of a breaker; 99999 practically disables it.
case "$MAX_PURGE" in
    ""|*[!0123456789]*|0*|??????*)
        die "MAX_PURGE must be a decimal integer from 1 to 99999," \
            "without a leading zero" ;;
esac

# TARSNAP_KEY and TARSNAP_PASSPHRASE end up in TARSNAP_KEYOPT, expanded
# unquoted so that the options vanish when empty (see below): a blank
# would split a value into two arguments. Refused here, rather than
# quoting every tarsnap call.
case "$TARSNAP_KEY" in
    *[[:space:]]*)
        die "TARSNAP_KEY must not contain whitespace: $TARSNAP_KEY" ;;
esac
case "$TARSNAP_PASSPHRASE" in
    *[[:space:]]*)
        die "TARSNAP_PASSPHRASE must not contain whitespace:" \
            "$TARSNAP_PASSPHRASE" ;;
esac

# The passphrase method must be one that tarsnap understands, otherwise it
# would stop on "Cannot parse passphrase entry method", after prebackup.
# The name of an env: variable is checked once and for all, since
# passphrase_reachable() hands it to eval: an explicit list rather than a
# range such as [A-Za-z], whose content depends on the locale.
case "$TARSNAP_PASSPHRASE" in
    ""|dev:tty-stdin|dev:tty-once|dev:stdin-once|env:[!0-9]*|file:?*) ;;
    *)
        die "invalid TARSNAP_PASSPHRASE, see the configuration block:" \
            "$TARSNAP_PASSPHRASE" ;;
esac
case "$TARSNAP_PASSPHRASE" in
    env:*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*)
        die "invalid variable name in TARSNAP_PASSPHRASE:" \
            "$TARSNAP_PASSPHRASE" ;;
esac

# The key must be readable, unless tarsnap.conf is relied upon.
if [ -n "$TARSNAP_KEY" ] && [ ! -r "$TARSNAP_KEY" ]; then
    die "tarsnap key not readable: $TARSNAP_KEY"
fi

# Passphrase-protected key. tarsnap reads the key again on each invocation,
# hence needs the passphrase again, up to three times per run: creation,
# listing, purge. By default, it asks through readpass() from libcperciva,
# which reads /dev/tty if it can open it, otherwise stdin, and only prompts
# on stderr when its source is a terminal. Without a terminal, as under
# cron, tarsnap fails on "EOF reading password", but only after prebackup,
# and therefore the dumps, have run. Hence this check, made here and in
# every mode, since all of them read the key (normal, --dry-run, -s and
# --orphans), rather than in prebackup, which is a user hook. A method set
# in TARSNAP_PASSPHRASE changes the condition, see passphrase_reachable():
# env: and file: need no terminal at all.
#
# "A terminal is available" is tested as close as possible to readpass():
#   - /dev/tty is really opened. [ -r /dev/tty ] would not do: the node is
#     mode 0666 and passes access() even without a controlling terminal,
#     only open() fails, with ENXIO. The subshell keeps set -e safe: a
#     failed redirection on exec, a special built-in, ends the subshell,
#     not the script.
#   - failing that, stdin must be a terminal, as after a setsid launched
#     from a terminal: readpass() then falls back on it and prompts there.
# A stdin that is not a terminal counts as no terminal, even with the
# passphrase piped into it: each tarsnap invocation, and the commands of
# prebackup, would read that same stdin.
#
# With TARSNAP_KEY empty, tarsnap itself is asked which key tarsnap.conf
# designates, see conf_keyfile(), and that key goes through the same check,
# below. When the answer is not reliable, the key stays out of sight: only
# an env: or file: method is then checked, and a protected key asked on
# the terminal still fails later, after prebackup. tarsnap-diff.sh assumes
# in that case that the key may prompt, which only costs it some display;
# here, the same assumption would block every cron job whose plain key is
# declared in tarsnap.conf.
if [ -n "$TARSNAP_KEY" ] && key_is_passphrased "$TARSNAP_KEY"; then
    if passphrase_reachable; then
        say "Passphrase-protected key: $PASSPHRASE_HOW."
    else
        die "passphrase-protected key, $PASSPHRASE_WHY:" \
            "$TARSNAP_KEY"
    fi
fi

# The key of tarsnap.conf, when tarsnap gives it reliably and it is
# readable: same check as for TARSNAP_KEY. An unreadable key is left to
# tarsnap, which names it in its own error message: refusing here would
# rest on a reading of tarsnap.conf that might be wrong.
CONF_KEY=""
if [ -z "$TARSNAP_KEY" ]; then
    CONF_KEY=$(conf_keyfile) || CONF_KEY=""
    if [ -n "$CONF_KEY" ] && [ ! -r "$CONF_KEY" ]; then
        CONF_KEY=""
    fi
fi
if [ -n "$CONF_KEY" ]; then
    say "Key from tarsnap.conf: $CONF_KEY."
    if key_is_passphrased "$CONF_KEY"; then
        if passphrase_reachable; then
            say "Passphrase-protected key: $PASSPHRASE_HOW."
        else
            die "passphrase-protected key, $PASSPHRASE_WHY:" \
                "$CONF_KEY (from tarsnap.conf)"
        fi
    fi
fi

# An env: or file: method with the key of tarsnap.conf out of sight: it was
# set for a protected key, so it is checked as well, rather than failing
# after prebackup. With a plain key known to the script, nothing is
# checked: tarsnap only reads the passphrase to decrypt a key.
if [ -z "$TARSNAP_KEY" ] && [ -z "$CONF_KEY" ]; then
    case "$TARSNAP_PASSPHRASE" in
        env:*|file:*)
            passphrase_reachable ||
                die "$PASSPHRASE_WHY (key from tarsnap.conf)" ;;
    esac
fi

# Locale: we want predictable output from tarsnap, apt and date.
if ! "$LOCALE_BIN" -a 2>/dev/null | "$GREP_BIN" -qix 'en_US\.utf-\?8'; then
    die "locale en_US.UTF-8 not generated on this system"
fi
unset LANGUAGE          # GNU gettext can override LC_MESSAGES, drop it
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
export LANG LC_ALL

# Options common to the tarsnap invocations. Deliberately left unquoted
# where they are used: they must vanish from the command line when they
# are empty.
if [ -n "$TARSNAP_KEY" ]; then
    TARSNAP_KEYOPT="--keyfile $TARSNAP_KEY"
else
    TARSNAP_KEYOPT=""
fi

# The passphrase method rides along with the key: TARSNAP_KEYOPT already
# reaches every tarsnap call, including the commands printed by --orphans
# and --dry-run.
if [ -n "$TARSNAP_PASSPHRASE" ]; then
    TARSNAP_KEYOPT="${TARSNAP_KEYOPT:+$TARSNAP_KEYOPT }--passphrase"
    TARSNAP_KEYOPT="$TARSNAP_KEYOPT $TARSNAP_PASSPHRASE"
fi

if [ "$VERBOSE" -eq 1 ]; then
    TARSNAP_MSGOPT="-v"
else
    # --quiet hides a few warnings ("Removing leading '/'", etc.), among
    # them "Archive contains no files": an exclusion pattern matching
    # everything would then go unnoticed, see check_excludes().
    # It is --no-print-stats that neutralises the print-stats directive of
    # tarsnap.conf, responsible for the "All archives / This archive /
    # New data" block printed on stderr in modes c and d. --no-totals and
    # --no-progress-bytes do the same for the totals and progress-bytes
    # directives; the latter requires tarsnap 1.0.40 or later.
    TARSNAP_MSGOPT="--quiet --no-print-stats --no-totals --no-progress-bytes"
fi

COMPUTER=$("$UNAME_BIN" -n)

# Strict stamp of the archive names, YYYY-MM-DD_HH-MM-SS. The digits are
# written in full rather than as the range [0-9]: the content of a range
# depends on the locale, and under bash [0-9] also matches digits other
# than 0 to 9. The expansion is left unquoted where it is used, so that it
# acts as a pattern and not as a literal string.
_digit='[0123456789]'
STAMP_GLOB="${_digit}${_digit}${_digit}${_digit}-${_digit}${_digit}"
STAMP_GLOB="${STAMP_GLOB}-${_digit}${_digit}_${_digit}${_digit}"
STAMP_GLOB="${STAMP_GLOB}-${_digit}${_digit}-${_digit}${_digit}"

# --orphans mode: read-only, hence no lock. The tarsnap man page only
# requires it for two concurrent create or delete operations, not for
# --list-archives: the archives can therefore be queried while a backup
# is running.
if [ "$ORPHANS" -eq 1 ]; then
    list_orphans
    exit 0
fi

# Non-blocking exclusive lock. It is held by descriptor 9, so the kernel
# releases it when the process dies, including on kill -9, OOM or power
# failure: no stale file to clean up by hand, and no possible race, unlike
# an existence test followed by a touch.
#
# exec is a special built-in: under dash, when its redirection fails the
# shell exits at once, before "|| die" can run, and the message is lost.
# The opening is therefore tried first in a subshell.
if ! (exec 9>"$LOCK_FILE") 2>/dev/null; then
    die "cannot open the lock: $LOCK_FILE"
fi
exec 9>"$LOCK_FILE" || die "cannot open the lock: $LOCK_FILE"
if ! "$FLOCK_BIN" -n 9; then
    die "another instance is already running (lock $LOCK_FILE)"
fi

###############################################################################
# STEP 1: BACKUP
###############################################################################

# Bare call, and above all NOT "prebackup || die ..." nor "if ! prebackup".
# Placing a function in a condition disables set -e throughout its body: a
# command failing in the middle would be ignored, the following ones would
# still run, and the function would return 0. Behaviour verified to be
# identical under dash and under bash. With the bare call, set -e stops
# the script on the failing command, whose message goes into the cron mail.
# run_hook() runs it in a subshell.
run_hook prebackup

NOW=$("$DATE_BIN" +%Y-%m-%d_%H-%M-%S)
if [ -n "$SNAPSHOT_NAME" ]; then
    # The suffix takes the archive out of the pattern tested by the
    # rotation: it becomes permanently untouchable by the purge.
    NAME="${COMPUTER}-${NOW}_${SNAPSHOT_NAME}"
else
    NAME="${COMPUTER}-${NOW}"
fi

# The --exclude options are built in the positional parameters: it is the
# only "array" POSIX sh has.
set --
for pattern in $BACKUP_EXCLUDE; do
    case "$pattern" in
        /*)
            # Absolute path, passed as is. tarsnap compares a pattern that
            # starts with / with the full path on disk, leading / included,
            # before stripping it from the entry name: the pattern is thus
            # anchored at the root, and only excludes this path. Without
            # its leading /, it would be tried at every level of the tree,
            # and would also exclude any directory of the same name further
            # down. The second pattern, for the contents, duplicates what
            # tarsnap already does for the leading directories, and stays
            # as a safety.
            set -- "$@" --exclude="$pattern" --exclude="$pattern/*"
            ;;
        *)
            # Pattern already relative or globbed, passed as is.
            set -- "$@" --exclude="$pattern"
            ;;
    esac
done

# In dry-run the creation is simulated too: tarsnap does not contact the
# server, and no archive is actually created. Two variants, chosen
# according to the requested level of verbosity.
if [ "$DRY" -eq 1 ]; then
    # --dry-run and not --dry-run-metadata. The latter, added in 1.0.41,
    # would nevertheless be much faster, as it reads no data. It fails as
    # soon as the chunk cache is populated:
    #
    #   tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
    #   tarsnap: Error writing cached archive entry
    #
    # Reproduced in 1.0.41 on each of the four directories of BACKUP_DIRS
    # taken individually, with a cachedir coming from a real backup. The
    # same call against a freshly initialised cachedir goes through without
    # a hitch, which isolates the cache as the only variable. print-stats
    # has nothing to do with it: the failure also occurs with
    # --no-print-stats.
    #
    # Cause, on the 1.0.41 source side: multitape_write.c:429 sets
    # no_chunkifiers = (dryrun == 2), which deprives the streams initialised
    # on lines 517 to 521 of a chunkifier, whereas the chunk layer d->C is
    # created on line 503 with no condition on dryrun. As a result,
    # writetape_ischunkpresent answers "present" where writetape_writechunk
    # returns 0, and ccache_entry.c:409 treats that 0 as a programmer error.
    #
    # Do not put the option back without checking that this has been fixed
    # upstream.
    set -- --dry-run "$@"
    say "Simulating archive ${NAME}."
else
    say "Creating archive ${NAME}."
fi

#
# The exit status is kept rather than left to set -e: postbackup must run
# whatever the outcome, and tarsnap -c exits with 2 when the archive was
# created but some files could not be read (a file deleted during the
# backup, a permission refused). The archive then exists: it is worth a
# warning, neither a silent success nor an abort.
CREATE_RC=0
# shellcheck disable=SC2086
"$TARSNAP_BIN" $TARSNAP_KEYOPT $TARSNAP_MSGOPT -c -f "$NAME" "$@" \
    $BACKUP_DIRS || CREATE_RC=$?

# Counterpart of prebackup, run whether this is a snapshot or a normal
# backup: whatever prebackup set up must be undone in every case.
# Bare call, for the same reason as above. It receives the exit status of
# tarsnap -c.
run_hook postbackup "$CREATE_RC"

case "$CREATE_RC" in
    0) ;;
    2)
        printf 'WARNING: tarsnap -c exited with status 2: some files\n' >&2
        printf '  could not be read, see the messages above. This run\n' >&2
        printf '  will exit with status 2.\n' >&2
        ;;
    *)
        die "tarsnap -c failed (exit status $CREATE_RC), no rotation" ;;
esac

# A snapshot is a one-off action: chaining three of them before going into
# production must not trigger three purges.
if [ -n "$SNAPSHOT_NAME" ]; then
    if [ "$DRY" -eq 1 ]; then
        say "Snapshot ${NAME} simulated, rotation skipped."
    else
        say "Snapshot ${NAME} created, rotation skipped."
    fi
    exit "$CREATE_RC"
fi

###############################################################################
# STEP 2: ROTATION
###############################################################################

NOW_UNIX=$("$DATE_BIN" +%s)

# Bounds of the three cumulative windows, expressed as an age counted from
# now. WEEKLY_SEC starts at the end of the daily window, and the monthly
# bound moves back by the same amount: an archive aged 100 days leaves the
# daily window (90 days) but falls into the weekly one, which runs from 90
# to 174 days.
#
# The variant with absolute windows, where all three would be counted from
# now, would require the invariant DAILY < WEEKLY*7 < MONTHLY*30. Without
# it, a tier silently becomes unreachable: with DAILY=90 and WEEKLY=12, the
# 84 days of the weekly window fit entirely within the 90 days of the daily
# one, and the father tier never keeps anything.
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

say "Fetching the list of archives."
# shellcheck disable=SC2086
ARCHIVES=$("$TARSNAP_BIN" $TARSNAP_KEYOPT --list-archives)

# Chronological order, oldest first: the weekly and monthly tiers keep the
# first archive of each period, so the oldest one of a period must be seen
# first. The names "hostname-YYYY-MM-DD_HH-MM-SS" sort that way by
# themselves under the C collation, whatever the locale of the run. The
# purge list follows the same order.
ARCHIVES=$(printf '%s\n' "$ARCHIVES" | LC_ALL=C "$SORT_BIN")

# After an exit status 2, nothing is deleted unless the archive of the run
# is listed: a status 2 does not prove by itself that it was written. In
# --dry-run nothing was created, and nothing will be deleted either.
if [ "$CREATE_RC" -eq 2 ] && [ "$DRY" -eq 0 ] &&
    ! printf '%s\n' "$ARCHIVES" | "$GREP_BIN" -Fqx -- "$NAME"; then
    die "archive $NAME not listed after an exit status 2, no rotation"
fi

# Start again from an empty set of positional parameters: it will serve as
# the accumulator of the "-f archive" pairs to delete.
set --

# Weeks and months already represented, as " key key ... ": in the
# chronological order above, the first archive of each period is the one
# kept.
SEEN_WEEKS=" "
SEEN_MONTHS=" "

# The naming pattern forbids spaces, so splitting on IFS is safe.
# One archive per line, read whole: a name containing a space or a tab is
# then one name, and not several words of which one could take the strict
# form and be passed to tarsnap -d. The list is fed by a here-document and
# not by a pipe, so that the loop runs in the current shell and the -f
# options it accumulates in "$@" survive it.
while IFS= read -r archive; do
    # Empty line: the account holds no archive at all.
    [ -n "$archive" ] || continue


    # The archive this very run created is never purged by its own run,
    # whatever the clock says. Its name is fixed before the creation and
    # NOW_UNIX is taken after it, so a run started late in the evening, a
    # creation that crosses midnight, the 25-hour day of the switch to
    # winter time, or a first full backup that lasts several days can push
    # its age past DAILY days; on a day that is neither DOW nor DOM, it
    # would then go with the purge, and the run would leave no archive at
    # all. In --dry-run nothing is created, so the name is never listed and
    # the simulation is unchanged.
    if [ "$archive" = "$NAME" ]; then
        say "Archive just created, kept: $archive"
        continue
    fi

    # Main safeguard: we touch ONLY what exactly matches
    # "hostname-YYYY-MM-DD_HH-MM-SS".
    # Everything else (snapshots created by hand) is beyond the reach of
    # the script.
    # shellcheck disable=SC2254
    case "$archive" in
        *.part)
            # Partial archive, left by an interrupted run: truncated on
            # purpose (^Q, SIGQUIT, --maxbw), or the last checkpoint of a run
            # that died (power failure, network), recovered by the next -c
            # or -d. It counts for deduplication and may
            # be of value: it is not deleted, a warning is issued instead.
            # The message goes to stderr, hence into the cron mail.
            printf 'WARNING: partial archive: %s\n' "$archive" >&2
            printf '  leftover of an interrupted run, to be handled by hand\n' >&2
            continue
            ;;
        "${COMPUTER}-"$STAMP_GLOB)
            ;;
        *)
            say "Outside the pattern, untouchable: $archive"
            continue
            ;;
    esac

    # "hostname-2026-09-05_14-30-00" -> "2026-09-05"
    stamp=${archive#"${COMPUTER}-"}
    day=${stamp%%_*}

    # The dates are computed from noon of the day, and its midnight is
    # taken as noon minus 12 hours: in some time zones a change to summer
    # time skips midnight itself (America/Havana, 8 March 2026), and
    # date -d "$day" then fails. On every other day, noon minus 12 hours is
    # that midnight.
    #
    # A name of the strict form whose date does not exist (30 February) is
    # kept with a warning, rather than stopping the rotation every night.
    if ! f_noon=$("$DATE_BIN" -d "$day 12:00" +%s 2>/dev/null); then
        printf 'WARNING: archive with an impossible date, kept: %s\n' \
            "$archive" >&2
        continue
    fi
    f_unix=$((f_noon - 43200))
    f_dow=$("$DATE_BIN" -d "$day 12:00" +%w)
    # %-d: no leading zero, hence no octal.
    f_dom=$("$DATE_BIN" -d "$day 12:00" +%-d)

    age=$((NOW_UNIX - f_unix))

    # Son: everything that is recent.
    if [ "$age" -lt "$DAILY_SEC" ]; then
        say "Daily (0 to $DAILY days), kept: $archive"
        continue
    fi

    # Month of the archive. A month starts on day DOM and ends the day
    # before the next DOM: moving the date back by DOM - 1 days lands in
    # the month that names it, for any DOM from 1 to 31, the short months
    # simply starting a few days later (with DOM=31, the month named
    # 2026-02 runs from 2026-03-03 to 2026-03-30). m_day is the first day
    # of that month, from which it counts in the window. Only needed while
    # the archive is newer than the monthly bound: an older month can no
    # longer count.
    m_key=""
    m_day=""
    m_unix=0
    if [ "$f_unix" -gt "$MONTHLY_UNIX" ]; then
        # Noon again, for the days without midnight. The relative item
        # comes first: placed after a time, "-N" would be read as a time
        # zone offset.
        m_key=$("$DATE_BIN" -d "-$((DOM - 1)) days $day 12:00" +%Y-%m)
        m_ref="+$((DOM - 1)) days ${m_key}-01 12:00"
        m_ref=$("$DATE_BIN" -d "$m_ref" '+%F %s')
        m_day=${m_ref% *}
        m_unix=$((${m_ref#* } - 43200))
    fi

    # Father: the first archive of each week, a week starting on day DOW,
    # as long as that day lies within the weekly window, which takes over
    # from the daily one and does not overlap it. When the night of DOW was
    # missed, the next archive of the week stands in for it, where the
    # exact day alone left the week without any archive. A week whose first
    # day has left the window no longer counts, even if some of its
    # archives are still inside: with no night missed, the archives kept
    # are exactly those of the exact day. The archive kept also represents
    # its month, so that the month does not get a second one below.
    if [ "$age" -lt "$WEEKLY_SEC" ]; then
        w_back=$(( (f_dow - DOW + 7) % 7 ))
        w_ref=$("$DATE_BIN" -d "-$w_back days $day 12:00" '+%F %s')
        w_key=${w_ref% *}
        w_unix=$((${w_ref#* } - 43200))
        if [ $((NOW_UNIX - w_unix)) -lt "$WEEKLY_SEC" ]; then
            case "$SEEN_WEEKS" in
                *" $w_key "*) ;;
                *)
                    SEEN_WEEKS="$SEEN_WEEKS$w_key "
                    SEEN_MONTHS="$SEEN_MONTHS$m_key "
                    say "Weekly ($DAILY to $((WEEKLY_SEC / 86400)) days)" \
                        "DOW=$f_dow, first of the week of $w_key," \
                        "kept: $archive"
                    continue
                    ;;
            esac
        fi
    fi

    # Grandfather: the first archive of each month, as defined above, as
    # long as its first day lies within the monthly window, which in turn
    # takes over from the weekly one. Same reasons as for the weeks: a
    # missed night of DOM no longer leaves a month without any archive.
    if [ -n "$m_key" ] && [ "$m_unix" -gt "$MONTHLY_UNIX" ]; then
        case "$SEEN_MONTHS" in
            *" $m_key "*) ;;
            *)
                SEEN_MONTHS="$SEEN_MONTHS$m_key "
                say "Monthly (beyond $((WEEKLY_SEC / 86400)) days)" \
                    "DOM=$f_dom, first of the month from $m_day," \
                    "kept: $archive"
                continue
                ;;
        esac
    fi

    set -- "$@" -f "$archive"
done <<_END_OF_ARCHIVE_LIST_
$ARCHIVES
_END_OF_ARCHIVE_LIST_

# Two parameters per archive (-f and the name).
COUNT=$(($# / 2))

if [ "$COUNT" -eq 0 ]; then
    say "Nothing to purge."
    exit "$CREATE_RC"
fi

say "$COUNT archive(s) to delete."

if [ "$DRY" -eq 1 ]; then
    printf 'Dry-run, command that would be executed:\n'
    printf '%s %s %s -d %s\n' \
        "$TARSNAP_BIN" "$TARSNAP_KEYOPT" "$TARSNAP_MSGOPT" "$*"
    if [ "$COUNT" -gt "$MAX_PURGE" ]; then
        printf 'WARNING: %s archives to delete, more than MAX_PURGE=%s:\n' \
            "$COUNT" "$MAX_PURGE" >&2
        printf '  a real run would stop here and delete nothing,\n' >&2
        printf '  unless given --force-purge\n' >&2
    fi
    exit "$CREATE_RC"
fi

# Purge circuit breaker, see MAX_PURGE. Only the real purge is stopped:
# the dry-run above prints the command and warns, since it is precisely
# the review that the message below asks for. Nothing is deleted, not even
# the first MAX_PURGE archives: whatever made the purge this large, a clock
# ahead, retention values changed by mistake or reset by a reinstalled
# script, makes its whole list untrustworthy. The archive of this run
# exists already, and postbackup has run.
if [ "$COUNT" -gt "$MAX_PURGE" ]; then
    if [ "$FORCE_PURGE" -eq 0 ]; then
        printf 'ERROR: %s archives to delete, more than MAX_PURGE=%s:\n' \
            "$COUNT" "$MAX_PURGE" >&2
        printf '  nothing was deleted: check the clock and the retention\n' >&2
        printf '  values, review with --dry-run --verbose, then rerun\n' >&2
        printf '  once with --force-purge\n' >&2
        exit 1
    fi
    say "MAX_PURGE=$MAX_PURGE lifted by --force-purge for this run."
fi

# A single call: the man page allows -f to be repeated in -d mode, and
# tarsnap caches the metadata, which noticeably speeds up a batch purge.
# shellcheck disable=SC2086
"$TARSNAP_BIN" $TARSNAP_KEYOPT $TARSNAP_MSGOPT -d "$@"

say "Done."
exit "$CREATE_RC"

# End of main(), opened above the option parsing.
}

# The last line of the file, read whole before main() starts: the shell
# reads nothing beyond it, and exit keeps it that way even if main()
# were ever to return. ShellCheck sees that main() always exits and
# reports this exit as unreachable (SC2317): it is there on purpose, and
# the braces only let the directive cover the whole line.
# shellcheck disable=SC2317
{ main "$@"; exit; }
