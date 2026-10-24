#!/bin/sh
#
# tarsnap-diff.sh
#
# Diff between a Tarsnap snapshot and the current state of the system,
# restricted to the directories covered by BACKUP_DIRS in tarsnap-backup.sh.
#
# Four categories, notation modelled on diff(1):
#   <  deleted    present in the snapshot, absent from the system
#   >  new        present on the system, absent from the snapshot
#   =  identical  present on both sides, content deemed identical
#   *  modified   present on both sides, content deemed different
#
# Without any option, all four categories are included. -d, -n, -i and -m
# select them and can be combined: -dn only keeps the deleted and the new.
#
# This choice has a deliberate side effect on the cost: the only network
# expense of the script, apart from the listing, serves to tell "identical"
# from "modified". If you asked for neither -i nor -m, it is short-circuited
# and the run becomes purely local once the listing has been obtained. The
# = and * counters then fall back on the metadata alone and are flagged as
# indicative, on screen as well as in the log; < and >, for their part,
# remain exact, as they depend on no download.
#
# The details go to a log file, not to the screen: on a real machine there
# are tens of thousands of lines, and a terminal's buffer is not an analysis
# tool. The detail lines are written as they come to a working file
# created next to the log, whose path -v prints, so you can follow the diff
# being built from another terminal while the script is running:
#
#     tail -f /var/log/tarsnap-diff.sh-<snapshot>.log.XXXXXXXX
#
# The header, which carries the four counters, is only added at the very
# end, at the top of the file, because the counters are obviously only
# known once everything has been classified. The finished log can therefore
# be read with a simple:
#
#     grep '^#' /var/log/tarsnap-diff.sh-<snapshot>.log
#
# which keeps the header alone, since no detail line starts with "#": 11
# lines, 13 in metadata-only mode, when the selected categories include
# neither -i nor -m, plus one line for each warning that applies, such as
# the exclusions of tarsnap.conf.
#
# The log itself is only replaced at the very end, by renaming onto its
# path a file that holds the header followed by the details: the operation
# is atomic, and a run that fails or is interrupted leaves the previous log
# of the same snapshot untouched (TD-11).
#
# The log is plain text, with no ANSI sequences: it is a file meant to be
# grepped ("grep '^\*'"), not terminal output.
#
# Only the numeric summary and the path of the log are printed on standard
# output, at the end.
#
###############################################################################
# HOW THE VERDICT IS REACHED
###############################################################################
#
# The listing of the archive gives, for each entry, its type, its size and
# its modification date. Nothing else, and above all no checksum: comparing
# two contents therefore requires downloading the one in the snapshot,
# which costs time and billed bandwidth. Hence three cases, only one of
# which touches the network.
#
#   Different sizes
#       The content necessarily differs: "modified", without downloading
#       anything. This is by far the most frequent case, and it is free.
#
#   Equal sizes, equal mtime
#       "identical". This is a heuristic, acknowledged as such: a file
#       rewritten with exactly the same size, whose mtime was then reset to
#       its original value, would slip through. So would, without anyone
#       meaning it, a file rewritten with the same size within the second
#       of the modification that the snapshot saw: the listing gives the
#       date to the second (N-R2-12). Strict mode is there for those who
#       are not satisfied with that.
#
#   Equal sizes, different mtime
#       Ambiguous, and the only case that justifies an actual read. The
#       file is downloaded from the snapshot, then compared byte by byte.
#       This eliminates the false "modified" of a file merely touched by a
#       touch, a sed -i that changes nothing or a restore. A chmod alone
#       never lands here: it only updates the ctime, and the file comes
#       out as "identical".
#
# Strict mode (-S): ALL the common regular files are downloaded and
# compared byte by byte, including those whose metadata match. It is the
# only absolute guarantee, but it downloads the whole common part of the
# snapshot. Keep it for a one-off check, and certainly not for a cron job.
# Without -i or -m it has nothing to reinforce: it is then inert, and the
# script tells you so rather than silently ignoring it.
#
# In both modes, the files to download are first gathered, then extracted
# in A SINGLE tarsnap invocation, through the -T option, which reads the
# list of names from a file. One invocation per file would reopen the
# archive on the server side every time, which becomes ruinous from a
# hundred files onwards.
#
# Directories and symbolic links: only their PRESENCE is compared. If they
# exist on both sides they are counted as "identical", since the listing
# does not provide what is needed to reliably judge a change of link target
# or of directory permissions. Devices, sockets and named pipes are
# ignored: they have no business being in BACKUP_DIRS. A hard link, which
# tarsnap lists with a size of 0 and the name of its target, is compared
# as the regular file it is (TD-04).
#
###############################################################################
#
# BACKUP_DIRS, BACKUP_EXCLUDE, TARSNAP_KEY and TARSNAP_PASSPHRASE are read
# from tarsnap-backup.sh, which is NEVER sourced, only read with sed:
# sourcing it would trigger its option parsing, its lock and, in the end, a
# real backup. Same precaution and same search order as rotation-check.sh.
#
# BACKUP_EXCLUDE can be overridden with -e. This is useful because the
# exclusions in force when the snapshot was taken cannot be reconstructed:
# the script necessarily applies today's, and if they have changed since,
# -e lets you replay the old ones.
#
# No archive is touched: only -tv and -x are used, both read-only on the
# Tarsnap side. The manual is explicit, "Extracting or listing archives may
# be performed in parallel with any other operation", hence no flock lock
# here, unlike tarsnap-backup.sh.

# -e: exit on the first error
# -u: an unset variable is an error
# -f: no globbing on unquoted expansions (BACKUP_DIRS, exclusion
#     patterns)
set -euf

#################
# CONFIGURATION #
#################

# --- Absolute paths of the binaries ---
#
# Hardcoded so as not to depend on the caller's $PATH, as in the rest of
# the suite. Values given for Debian with usrmerge, hence everything under
# /usr/bin.
TARSNAP_BIN="/usr/bin/tarsnap"
FIND_BIN="/usr/bin/find"
SORT_BIN="/usr/bin/sort"
JOIN_BIN="/usr/bin/join"
CMP_BIN="/usr/bin/cmp"
SED_BIN="/usr/bin/sed"
GREP_BIN="/usr/bin/grep"
DATE_BIN="/usr/bin/date"
MKTEMP_BIN="/usr/bin/mktemp"
MKDIR_BIN="/usr/bin/mkdir"
RM_BIN="/usr/bin/rm"
MV_BIN="/usr/bin/mv"
CAT_BIN="/usr/bin/cat"
SLEEP_BIN="/usr/bin/sleep"
LOCALE_BIN="/usr/bin/locale"

# stdbuf is NOT mandatory: without it, the spinner loses its live counter
# and falls back to a bare spinning wheel. It comes from GNU coreutils, is
# also part of the FreeBSD base system since 8.4, but is absent from
# macOS: hence an existence test further down rather than an entry in the
# list of required binaries.
STDBUF_BIN="/usr/bin/stdbuf"

# --- Log ---
#
# Directory where the log is written. Do not put it in a directory covered
# by BACKUP_DIRS: the log would show up in its own diff, as a new file. The
# script warns you if that happens.
LOG_DIR="/var/log"

# --- Location of tarsnap-backup.sh ---
#
# Search order: the installed path below, then, failing that, a
# tarsnap-backup.sh next to this script, in its own directory, which covers
# the case of a freshly cloned repository. The -f option bypasses both.
BACKUP_SCRIPT_INSTALLED="/usr/local/sbin/tarsnap-backup.sh"

###############################################################################
# END OF CONFIGURATION
###############################################################################

BACKUP_SCRIPT=""
SHOW_DELETED=0
SHOW_NEW=0
SHOW_IDENTICAL=0
SHOW_MODIFIED=0
ANY_CATEGORY=0
STRICT=0
VERBOSE=0
DEBUG=0
OPT_EXCLUDE=""
OPT_EXCLUDE_SET=0
OPT_LOGFILE=""

# The only place where a binary is called without its absolute path:
# usage() can be reached through --help BEFORE the safeguard loop, and a
# wrong "$CAT_BIN" would make the help fail there instead of displaying
# it. It is also exactly the idiom used by tarsnap-backup.sh and
# rotation-check.sh.
usage() {
    # The continuation line of the synopsis is aligned under the first
    # option, whatever the name the script was installed under: as many
    # spaces as "usage: " plus that name, counted with parameter expansions
    # only, so still without any external binary.
    _pad="       "
    _rest=${0##*/}
    while [ -n "$_rest" ]; do
        _pad="$_pad "
        _rest=${_rest#?}
    done
    cat >&2 <<EOF
usage: ${0##*/} [-d] [-n] [-i] [-m] [-S] [-v] [-e "patterns"]
$_pad [-l log] [-f script] [--debug] SNAPSHOT

  -d, --deleted         include the files deleted since the snapshot
  -n, --new             include the new files, absent from the snapshot
  -i, --identical       include the identical files
  -m, --modified        include the modified files
                        Without any of these four, everything is included.
  -S, --strict          strict check: download and compare byte by byte
                        ALL the common files, and not only those whose
                        metadata differ. Slow, and billed by Tarsnap per
                        volume transferred. No effect if neither -i nor -m
                        is requested, which the script reports.
  -v, --verbose         detail the progress on standard error
  -e, --exclude PATTERNS
                        override BACKUP_EXCLUDE, patterns in quotes and
                        separated by spaces, -e "" for none; the
                        exclusions of tarsnap.conf still apply
  -l, --log FILE        path of the log
                        (default: $LOG_DIR/${0##*/}-SNAPSHOT.log)
  -f, --file SCRIPT     path of tarsnap-backup.sh, from which BACKUP_DIRS,
                        BACKUP_EXCLUDE, TARSNAP_KEY and TARSNAP_PASSPHRASE
                        are read
      --debug           trace the execution (set -x), and keep the
                        temporary directory, whose path is displayed
  -h, --help            display this help

SNAPSHOT is the exact name of an existing archive, as listed by
"tarsnap --list-archives".
EOF
    exit "${1:-1}"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Progress, on standard error so as to leave standard output to the
# summary alone. The "return 0" is essential: without it, a false [ ]
# would make the script exit because of set -e. Same pattern as the say()
# of tarsnap-backup.sh.
say() {
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" >&2
    return 0
}

dbg() {
    [ "$DEBUG" -eq 1 ] && printf 'DEBUG: %s\n' "$*" >&2
    return 0
}

# --- Translating the long forms ---
#
# POSIX getopts only knows single-character options: the long forms are
# rewritten as short forms before running it, with one or two dashes
# accepted. Same mechanism as tarsnap-backup.sh.
#
# --debug becomes -X, a letter deliberately absent from the documented
# short forms: it is a debugging option, not one for everyday use.
for arg do
    shift
    case "$arg" in
        --help|-help)           usage 0 ;;
        --deleted|-deleted)     set -- "$@" -d ;;
        --new|-new)             set -- "$@" -n ;;
        --identical|-identical) set -- "$@" -i ;;
        --modified|-modified)   set -- "$@" -m ;;
        --strict|-strict)       set -- "$@" -S ;;
        --verbose|-verbose)     set -- "$@" -v ;;
        --debug|-debug)         set -- "$@" -X ;;
        # Attached form: we split on the first "=" ourselves.
        --exclude=*|-exclude=*) set -- "$@" -e "${arg#*=}" ;;
        --log=*|-log=*)         set -- "$@" -l "${arg#*=}" ;;
        --file=*|-file=*)       set -- "$@" -f "${arg#*=}" ;;
        # Separate form: we only emit the letter, the value follows in $@
        # and getopts will pick it up, including to complain if it is
        # missing.
        --exclude|-exclude)     set -- "$@" -e ;;
        --log|-log)             set -- "$@" -l ;;
        --file|-file)           set -- "$@" -f ;;
        *)                      set -- "$@" "$arg" ;;
    esac
done

while getopts "dnimSvXe:l:f:h" option; do
    case "$option" in
        d) SHOW_DELETED=1;   ANY_CATEGORY=1 ;;
        n) SHOW_NEW=1;       ANY_CATEGORY=1 ;;
        i) SHOW_IDENTICAL=1; ANY_CATEGORY=1 ;;
        m) SHOW_MODIFIED=1;  ANY_CATEGORY=1 ;;
        S) STRICT=1 ;;
        v) VERBOSE=1 ;;
        X) DEBUG=1; VERBOSE=1 ;;
        e) OPT_EXCLUDE=$OPTARG; OPT_EXCLUDE_SET=1 ;;
        l) OPT_LOGFILE=$OPTARG ;;
        f) BACKUP_SCRIPT=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$DEBUG" -eq 1 ]; then
    set -x
fi

if [ "$ANY_CATEGORY" -eq 0 ]; then
    SHOW_DELETED=1; SHOW_NEW=1; SHOW_IDENTICAL=1; SHOW_MODIFIED=1
fi

# The byte-by-byte check only exists to tell "identical" from "modified".
# If you asked for neither, it settles nothing you wanted to know: no
# point paying for the download. It is the only item of network expense
# of the script, so "tarsnap-diff.sh -d" becomes purely local once the
# listing has been obtained.
#
# The other steps, on the other hand, can NOT be skipped: "deleted" and
# "new" are deduced by matching the two complete inventories, so the
# archive must be listed AND the system walked in every case.
NEED_BYTE_CHECK=0
if [ "$SHOW_IDENTICAL" -eq 1 ] || [ "$SHOW_MODIFIED" -eq 1 ]; then
    NEED_BYTE_CHECK=1
fi

[ $# -eq 1 ] || usage 1
SNAPSHOT_NAME=$1

NL='
'

# The snapshot name ends up in the default name of the log: anything that
# would introduce a "/", a space or an exotic character is then refused.
# An explicit list rather than a range such as [A-Za-z], whose content
# depends on the locale. The dot is allowed, for the .part archives.
# With -l, the name only reaches tarsnap, quoted, and the screen: Tarsnap
# accepts other names, and so does the script then, except a "/", which no
# archive of the suite holds, and the control characters, which would
# drive the terminal (TD-09).
case "$SNAPSHOT_NAME" in
    "") die "empty snapshot name" ;;
esac
if [ -z "$OPT_LOGFILE" ]; then
    case "$SNAPSHOT_NAME" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
            die "invalid snapshot name, allowed characters: A-Z a-z 0-9 _ - ." \
                "(any other name needs -l)" ;;
    esac
else
    case "$SNAPSHOT_NAME" in
        */*|*"$NL"*)
            die "invalid snapshot name: no / and no control character" ;;
    esac
    _ctl=$(printf '%s\n' "$SNAPSHOT_NAME" | LC_ALL=C "$SED_BIN" -n '/[[:cntrl:]]/p')
    [ -z "$_ctl" ] || die "invalid snapshot name: no / and no control character"
fi

###############################################################################
# READING THE CONFIGURATION OF tarsnap-backup.sh
###############################################################################

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
        # often runs with other values, and the diff would describe another
        # configuration than the one of the backups (N-R1-21, RC-05).
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

# Reading a NAME="..." value from the backup script.
#
# Unlike the read_value of rotation-check.sh, which reads integers that are
# never empty, an empty value is perfectly legitimate here: TARSNAP_KEY=""
# is the documented "I rely on tarsnap.conf" case. Hence the preliminary
# grep, which tells "declared and empty" from "not declared at all", where
# a silent sed would confuse the two.
#
# The value stops at the first double quote after the opening one, so that
# a trailing comment may contain double quotes of its own, as in
#   TARSNAP_KEY="/root/tarsnap.key" # see "keyfile"
# The value itself can therefore hold no double quote, which none of the
# variables read here needs.
#
# A second line assigning the same name is refused: the shell keeps the
# last assignment, and reading the first one would compare against another
# configuration than the backup's. Same rule as read_value() in
# rotation-check.sh.
read_string() {
    _name=$1
    _lines=$("$SED_BIN" -n "/^${_name}=/=" "$BACKUP_SCRIPT")
    case "$_lines" in
        *[!0123456789]*)
            die "$_name is assigned on more than one line in $BACKUP_SCRIPT" ;;
    esac
    "$GREP_BIN" -q "^${_name}=\"" "$BACKUP_SCRIPT" \
        || die "variable $_name not found in $BACKUP_SCRIPT"
    "$SED_BIN" -n "/^${_name}=/{s/^${_name}=\"\([^\"]*\)\".*/\1/p;q;}" "$BACKUP_SCRIPT"
}

TARSNAP_KEY=$(read_string TARSNAP_KEY)
BACKUP_DIRS=$(read_string BACKUP_DIRS)
BACKUP_EXCLUDE=$(read_string BACKUP_EXCLUDE)
TARSNAP_PASSPHRASE=$(read_string TARSNAP_PASSPHRASE)

# -e replaces BACKUP_EXCLUDE, even with an empty value: -e "" replays a
# snapshot taken without exclusions (TD-07).
if [ "$OPT_EXCLUDE_SET" -eq 1 ]; then
    BACKUP_EXCLUDE=$OPT_EXCLUDE
    say "BACKUP_EXCLUDE overridden: ${BACKUP_EXCLUDE:-none}"
fi

dbg "BACKUP_SCRIPT=$BACKUP_SCRIPT"
dbg "BACKUP_DIRS=$BACKUP_DIRS"
dbg "BACKUP_EXCLUDE=$BACKUP_EXCLUDE"

###############################################################################
# SAFEGUARDS
###############################################################################

for bin in "$TARSNAP_BIN" "$FIND_BIN" "$SORT_BIN" "$JOIN_BIN" "$CMP_BIN" \
           "$SED_BIN" "$GREP_BIN" "$DATE_BIN" "$MKTEMP_BIN" "$MKDIR_BIN" \
           "$RM_BIN" "$MV_BIN" "$CAT_BIN" "$SLEEP_BIN" "$LOCALE_BIN"; do
    [ -x "$bin" ] || die "binary missing or not executable: $bin"
done

# tarsnap runs in en_US.UTF-8, as in tarsnap-backup.sh, whatever the locale
# of the caller: it then writes the names of the listing that are valid
# UTF-8 as they are, escapes the others always the same way, and reads the
# pax headers of the archive without failing (TD-05). Only the two tarsnap
# calls get it; sort and join keep LC_ALL=C.
if ! "$LOCALE_BIN" -a 2>/dev/null | "$GREP_BIN" -qix 'en_US\.utf-\?8'; then
    die "locale en_US.UTF-8 not generated on this system"
fi

[ -n "$BACKUP_DIRS" ] || die "BACKUP_DIRS is empty in $BACKUP_SCRIPT"

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

# Same normalisation as tarsnap-backup.sh, so that the walk and the
# exclusions match what the backup really archived.
check_dirs
check_excludes

# Exclusions of tarsnap.conf. tarsnap -c applied them when it made the
# snapshot, on top of BACKUP_EXCLUDE, and tarsnap would apply them again
# to the listing and to the extraction, silently and on one side only.
# The two tarsnap calls therefore get --no-config-exclude and
# --no-config-include, and these patterns join BACKUP_EXCLUDE in
# is_excluded(), on both sides, shown in the header of the log; -e does
# not replace them (N-R1-19). Read like conf_keyfile() does, but every
# "  exclude" line counts, of every file read, since tarsnap adds them
# all up; the trailing slashes go as in check_excludes(). A pattern holding
# a blank cannot enter the list, and an include directive is not
# reproduced: both are reported.
conf_excludes() {
    _ce_dump=$("$TARSNAP_BIN" --dump-config 2>&1 >/dev/null) || return 1
    printf '%s\n' "$_ce_dump" | "$SED_BIN" -n \
        -e '1,/^Reading from config file: /d' \
        -e 's/^  \(exclude\|include\)[[:space:]]*/\1 /p'
}
CONF_EXCLUDE=""
if _ce_lines=$(conf_excludes); then
    while IFS= read -r _ce; do
        case "$_ce" in
            "include "*)
                printf 'WARNING: tarsnap.conf has an include directive, which tarsnap-diff.sh does not reproduce: %s\n' \
                    "${_ce#include }" >&2
                continue ;;
        esac
        _ce=${_ce#exclude }
        while :; do
            case "$_ce" in
                ?*/) _ce=${_ce%/} ;;
                *) break ;;
            esac
        done
        case "$_ce" in
            ""|/) continue ;;
            *[[:space:]]*)
                printf 'WARNING: exclusion of tarsnap.conf with a blank, not applied by tarsnap-diff.sh: %s\n' \
                    "$_ce" >&2
                continue ;;
        esac
        CONF_EXCLUDE="${CONF_EXCLUDE:+$CONF_EXCLUDE }$_ce"
    done <<EOF
$_ce_lines
EOF
else
    printf 'WARNING: the exclusions of tarsnap.conf could not be read, "tarsnap --dump-config" failed\n' >&2
fi
dbg "CONF_EXCLUDE=$CONF_EXCLUDE"

# -S only reinforces the identical/modified distinction: without -i or -m,
# it has nothing to reinforce. We say so rather than silently ignoring it.
if [ "$STRICT" -eq 1 ] && [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    printf 'WARNING: -S has no effect here, since neither -i nor -m is requested.\n' >&2
fi

# TARSNAP_KEY and TARSNAP_PASSPHRASE end up in TARSNAP_KEYOPT, expanded
# unquoted so that the options vanish when empty (see below): a blank
# would split a value into two arguments. Refused here, rather than
# quoting every tarsnap call, as in tarsnap-backup.sh.
case "$TARSNAP_KEY" in
    *[[:space:]]*)
        die "TARSNAP_KEY must not contain whitespace, see $BACKUP_SCRIPT:" \
            "$TARSNAP_KEY" ;;
esac
# The messages below do not repeat the value of TARSNAP_PASSPHRASE: a value
# that fails these checks may be the passphrase itself, written there by
# mistake, and it would end up in the cron mail.
case "$TARSNAP_PASSPHRASE" in
    *[[:space:]]*)
        die "TARSNAP_PASSPHRASE must not contain whitespace, see" \
            "$BACKUP_SCRIPT (value not shown)" ;;
esac

# The passphrase method must be one that tarsnap understands, otherwise it
# would stop on "Cannot parse passphrase entry method", at the listing.
# The name of an env: variable is checked once and for all, since
# passphrase_reachable() hands it to eval: an explicit list rather than a
# range such as [A-Za-z], whose content depends on the locale. Same lists
# as in tarsnap-backup.sh.
case "$TARSNAP_PASSPHRASE" in
    ""|dev:tty-stdin|dev:tty-once|dev:stdin-once|env:[!0-9]*|file:?*) ;;
    *)
        die "invalid TARSNAP_PASSPHRASE, see $BACKUP_SCRIPT" \
            "(value not shown)" ;;
esac
case "$TARSNAP_PASSPHRASE" in
    env:*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*)
        die "invalid variable name in TARSNAP_PASSPHRASE, see" \
            "$BACKUP_SCRIPT (value not shown)" ;;
esac

# Shown only now, once its syntax has been checked: before that, it could
# be the passphrase itself, written there by mistake.
dbg "TARSNAP_PASSPHRASE=$TARSNAP_PASSPHRASE"

if [ -n "$TARSNAP_KEY" ] && [ ! -r "$TARSNAP_KEY" ]; then
    die "tarsnap key not readable: $TARSNAP_KEY"
fi

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
# Kept identical to the function of the same name in tarsnap-backup.sh.
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
# empty passphrase and fail on it, later on. A file that is not a
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
            # ${NAME:+x} rather than the value itself: under set -x, the
            # --debug of tarsnap-diff.sh, the trace shows x, and not the
            # passphrase.
            _pp_set=""
            eval "_pp_set=\${$_pp_name:+x}"
            [ -n "$_pp_set" ]
            ;;
        file:*)
            _pp_file=${TARSNAP_PASSPHRASE#file:}
            PASSPHRASE_HOW="read from $_pp_file"
            PASSPHRASE_WHY="passphrase file $_pp_file unreadable,"
            PASSPHRASE_WHY="$PASSPHRASE_WHY empty or not a single line"
            [ -r "$_pp_file" ] || return 1
            [ -f "$_pp_file" ] || return 0
            # tarsnap ends the passphrase at the first CR or LF: a single
            # line that is empty, or starts with a CR, gives an empty
            # passphrase. sed answers y or nothing: the passphrase itself
            # never reaches the shell, nor its trace.
            _pp_sed='1{/^\r/d;/^$/d;s/.*/y/p;}'
            [ -s "$_pp_file" ] &&
                [ "$("$SED_BIN" -n '$=' "$_pp_file")" = 1 ] &&
                [ "$("$SED_BIN" -n "$_pp_sed" "$_pp_file")" = y ]
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

# The key whose passphrase matters is TARSNAP_KEY, or else the key that
# tarsnap.conf designates, as tarsnap itself reports it, see conf_keyfile().
# An unreadable key of tarsnap.conf is left to tarsnap, which names it in
# its own error message. Same reading as tarsnap-backup.sh.
CONF_KEY=""
if [ -z "$TARSNAP_KEY" ]; then
    CONF_KEY=$(conf_keyfile) || CONF_KEY=""
    if [ -n "$CONF_KEY" ] && [ ! -r "$CONF_KEY" ]; then
        CONF_KEY=""
    fi
fi
if [ -n "$CONF_KEY" ]; then
    say "Key from tarsnap.conf: $CONF_KEY."
    KEY_EFF=$CONF_KEY
    KEY_WHERE="$CONF_KEY (from tarsnap.conf)"
else
    KEY_EFF=$TARSNAP_KEY
    KEY_WHERE=$TARSNAP_KEY
fi

# A protected key whose passphrase cannot be obtained is refused here,
# before the log is opened: the listing would fail anyway on the first
# tarsnap call, and the previous log of the same snapshot would already
# have been emptied. When the key stays out of sight, only an env: or
# file: method is checked, as in tarsnap-backup.sh: it was set for a
# protected key.
#
# KEY_MAY_PROMPT=1 when tarsnap may ask for the passphrase on the terminal,
# so that the display keeps out of its way (spinner, stderr of the
# download): a protected key with a dev: method or the default one, or a
# key out of sight without env: or file:, the script then playing it safe.
# tarsnap only reads the passphrase to decrypt a key: a plain key never
# prompts, whatever the method. Each tarsnap invocation reads the key
# again, hence asks again: once for the listing, once more if files have
# to be downloaded.
if [ -n "$KEY_EFF" ]; then
    if key_is_passphrased "$KEY_EFF"; then
        if passphrase_reachable; then
            say "Passphrase-protected key: $PASSPHRASE_HOW."
        else
            die "passphrase-protected key, $PASSPHRASE_WHY: $KEY_WHERE"
        fi
        case "$TARSNAP_PASSPHRASE" in
            env:*|file:*) KEY_MAY_PROMPT=0 ;;
            *)            KEY_MAY_PROMPT=1 ;;
        esac
    else
        KEY_MAY_PROMPT=0
    fi
else
    case "$TARSNAP_PASSPHRASE" in
        env:*|file:*)
            passphrase_reachable ||
                die "$PASSPHRASE_WHY (key from tarsnap.conf)"
            KEY_MAY_PROMPT=0 ;;
        *)
            KEY_MAY_PROMPT=1 ;;
    esac
fi
dbg "KEY_MAY_PROMPT=$KEY_MAY_PROMPT"

# Options common to the tarsnap invocations. Deliberately left unquoted
# where they are used: they must vanish from the command line when they
# are empty. Same convention as tarsnap-backup.sh.
if [ -n "$TARSNAP_KEY" ]; then
    TARSNAP_KEYOPT="--keyfile $TARSNAP_KEY"
else
    TARSNAP_KEYOPT=""
fi

# The passphrase method rides along with the key, as in tarsnap-backup.sh:
# TARSNAP_KEYOPT reaches both tarsnap calls, the listing and the download.
if [ -n "$TARSNAP_PASSPHRASE" ]; then
    TARSNAP_KEYOPT="${TARSNAP_KEYOPT:+$TARSNAP_KEYOPT }--passphrase"
    TARSNAP_KEYOPT="$TARSNAP_KEYOPT $TARSNAP_PASSPHRASE"
fi

# --- Checking the path of the log ---
if [ -n "$OPT_LOGFILE" ]; then
    LOGFILE=$OPT_LOGFILE
else
    LOGFILE="${LOG_DIR}/${0##*/}-${SNAPSHOT_NAME}.log"
fi
case "$LOGFILE" in
    */*) LOGDIR_EFF=${LOGFILE%/*} ;;
    *)   LOGDIR_EFF="." ;;
esac
[ -n "$LOGDIR_EFF" ] || LOGDIR_EFF=/
[ -d "$LOGDIR_EFF" ] || die "log directory does not exist: $LOGDIR_EFF"
[ ! -d "$LOGFILE" ] || die "log path is a directory: $LOGFILE"

# The path of the log is made absolute and canonical, its directory being
# resolved by the shell itself: a relative -l, a "//" or a symbolic link in
# the directory part would otherwise escape the check against BACKUP_DIRS
# below (TD-08). The last component is kept as given, and checked next.
LOGDIR_EFF=$(CDPATH='' cd -P -- "$LOGDIR_EFF" && pwd -P) \
    || die "log directory not accessible: $LOGDIR_EFF"
LOGFILE="${LOGDIR_EFF%/}/${LOGFILE##*/}"

# Only a regular file, or nothing yet, is accepted under the name of the
# log: the final rename would replace a device such as /dev/null, or a
# symbolic link, with a regular file, for every other user of that name
# until the next reboot (N-R3-2).
if [ -L "$LOGFILE" ] || { [ -e "$LOGFILE" ] && [ ! -f "$LOGFILE" ]; }; then
    die "log path is not a regular file: $LOGFILE"
fi

# Working files of the log, both created by mktemp next to it: LOGFILE_WORK
# once the temporary directory exists, for the detail lines as they come,
# and LOGFILE_TMP in step 6, for the header followed by those lines.
# Nothing touches the log itself before the final rename, so a run that
# fails or is interrupted leaves the previous log of the same snapshot as
# it was (TD-11). Declared here, empty, because cleanup() must be able to
# test them, and set -u would kill the script on a variable still
# undefined at the time of a signal.
LOGFILE_WORK=""
LOGFILE_TMP=""

# Timestamp taken at the START and kept: the header is only written at the
# end, but it is indeed the launch time that interests you, not the time
# at which the script finished copying.
STARTED_AT=$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')

# The log must not land in the compared tree, otherwise it shows up in its
# own diff. Not blocking, it is cosmetic: we warn, and carry on.
for _d in $BACKUP_DIRS; do
    case "$LOGFILE" in
        "$_d"/*)
            printf 'WARNING: the log %s is under %s, covered by BACKUP_DIRS.\n' \
                "$LOGFILE" "$_d" >&2
            printf '         it will show up in its own diff, as a new file.\n' >&2
            ;;
    esac
done

###############################################################################
# TEMPORARY FILES, SPINNER AND CLEANUP
###############################################################################

TMP_DIR=""
SPINNER_PID=""

# Idempotent cleanup: the HUP, INT and TERM handlers go through it a
# second time via the EXIT trap, which has no effect.
#
# SC2317 and SC2329 are disabled here: shellcheck does not follow calls
# made from a trap, and therefore believes the whole body is dead (SC2317)
# or the function never invoked (SC2329, from ShellCheck 0.11.0 on). It is
# not.
# shellcheck disable=SC2317,SC2329
cleanup() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # Erasing with a fixed-width field: no ANSI sequence, so this also
        # holds up on a dumb terminal.
        # "|| true" on every write of this function: after a HUP the
        # terminal is gone, and under set -e a write that fails here
        # would end the cleanup halfway, with the exit status of printf
        # instead of 128 + the signal (N-R1-18).
        printf '\r%78s\r' '' >&2 || true
    fi
    # A temporary directory that cannot be removed, a file marked immutable
    # for instance, gives a warning instead of stopping the cleanup
    # (N-R1-17).
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        if [ "$DEBUG" -eq 1 ]; then
            printf 'DEBUG: temporary directory kept: %s\n' "$TMP_DIR" >&2 || true
        else
            "$RM_BIN" -rf "$TMP_DIR" ||
                printf 'WARNING: could not remove the temporary directory: %s\n' \
                    "$TMP_DIR" >&2 || true
        fi
    fi
    # The working files of the log only make sense until the final rename,
    # which resets both variables to empty. If one of them is still lying
    # around here, we exited halfway through: the previous log stays as it
    # was, and these files must not survive next to it, where they would
    # look like a second, truncated log. --debug keeps the details file, as
    # it keeps the temporary directory.
    if [ -n "$LOGFILE_TMP" ] && [ -f "$LOGFILE_TMP" ]; then
        "$RM_BIN" -f "$LOGFILE_TMP" ||
            printf 'WARNING: could not remove %s\n' "$LOGFILE_TMP" >&2 || true
    fi
    if [ -n "$LOGFILE_WORK" ] && [ -f "$LOGFILE_WORK" ]; then
        if [ "$DEBUG" -eq 1 ]; then
            printf 'DEBUG: details of the log kept: %s\n' "$LOGFILE_WORK" >&2 || true
        else
            "$RM_BIN" -f "$LOGFILE_WORK" ||
                printf 'WARNING: could not remove %s\n' "$LOGFILE_WORK" >&2 || true
        fi
    fi
    return 0
}

# The signal handlers EXIT after cleaning up, and that is the whole point
# of separating them from the EXIT trap. A mere "trap cleanup INT" would
# clean up and then let the script carry on with a temporary directory
# that has just been erased, and what follows would derail in cascade on
# "Directory nonexistent" errors. Exit codes 128 + signal number, as a
# shell does. QUIT, Ctrl-\ on a terminal, needs its own handler too: a
# non-interactive shell keeps its default action, which ends the script
# without going through the EXIT trap, hence without any cleanup (N-R1-18).
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 131' QUIT
trap 'cleanup; exit 143' TERM

# mktemp without a template creates $TMPDIR/tmp.XXXXXXXXXX, i.e.
# /tmp/tmp.XXXXXXXXXX when TMPDIR is empty: a name that means nothing to
# anyone when it turns up in an error message. With a template, it
# announces itself.
TMP_DIR=$("$MKTEMP_BIN" -d "${TMPDIR:-/tmp}/tarsnap-diff.XXXXXXXX") \
    || die "cannot create the temporary directory in ${TMPDIR:-/tmp}"
dbg "TMP_DIR=$TMP_DIR"

# The working file of the log: a random name created with O_EXCL, in mode
# 0600, so that nothing planted beforehand under that name can be followed
# or reused. It is opened at once, for appending on descriptor 3 and for
# reading on descriptor 4, and never reopened by its path: replacing that
# name during the run no longer changes what the script writes or reads
# (N-R1-16). The probe in a subshell comes first because, under dash, a
# redirection of exec that fails stops the shell before die can speak
# (TB-08, TD-12).
LOGFILE_WORK=$("$MKTEMP_BIN" "${LOGFILE}.XXXXXXXX") \
    || die "log not writable: cannot create a file next to $LOGFILE"
if ! (exec 3>>"$LOGFILE_WORK") 2>/dev/null ||
        ! (exec 4<"$LOGFILE_WORK") 2>/dev/null; then
    die "log not writable: $LOGFILE_WORK"
fi
exec 3>>"$LOGFILE_WORK"
exec 4<"$LOGFILE_WORK"
dbg "LOGFILE_WORK=$LOGFILE_WORK"
say "Details written as they come to $LOGFILE_WORK."

ARCHIVE_RAW="$TMP_DIR/archive.raw"
ARCHIVE_META="$TMP_DIR/archive.meta"
LOCAL_RAW="$TMP_DIR/local.raw"
LOCAL_META="$TMP_DIR/local.meta"
DELETED_LIST="$TMP_DIR/deleted"
NEW_LIST="$TMP_DIR/new"
COMMON_LIST="$TMP_DIR/common"
CANDIDATES="$TMP_DIR/candidates"
VERDICTS="$TMP_DIR/verdicts"
EXTRACT_DIR="$TMP_DIR/extract"
TARSNAP_ERR="$TMP_DIR/tarsnap.err"
ARCHIVE_FILES="$TMP_DIR/archive.files"
HARD_RAW="$TMP_DIR/hard.raw"
HARD_LIST="$TMP_DIR/hardlinks"
HARD_BY_NAME="$TMP_DIR/hardlinks.byname"
PATTERNS="$TMP_DIR/patterns"

TAB=$(printf '\t')
SOH=$(printf '\001')

# The control bytes of a name, ESC, CR or BS for instance, would drive the
# terminal of whoever reads the log with cat or less -R, or reads the
# warnings: they are written as "?", under LC_ALL=C so that only the bytes
# 0x01 to 0x1f and 0x7f are touched, whatever the locale (N-R3-4).
# Newlines and tabs never get this far, those names stay out of the
# inventories. Only a line that holds such a byte pays for the sed.
ctl_safe() {
    case "$1" in
        *[[:cntrl:]]*)
            printf '%s\n' "$1" | LC_ALL=C "$SED_BIN" 's/[[:cntrl:]]/?/g' ;;
        *)
            printf '%s\n' "$1" ;;
    esac
}

# Spinner, taken from tarsnap-stats.sh. Two modes: "count" displays the
# number of lines already received in the watched file, "plain" merely
# spins. In count mode, strictly nothing is drawn as long as the watched
# file is empty: during that window tarsnap may still ask for the key
# passphrase, and the progress line must above all not land on top of it.
# Plain mode has nothing to watch and would draw at once over such a
# prompt: it is therefore not started at all when the key may ask for a
# passphrase (KEY_MAY_PROMPT). TARSNAP_SPINNER=0 disables the spinner.
#
# $1 label, $2 "count" or "plain", $3 file to count in count mode.
spin_start() {
    [ "${TARSNAP_SPINNER:-1}" = 1 ] || return 0
    [ -t 2 ] || return 0
    # The spinner and set -x do not mix: the trace of the subshell would
    # flood the terminal.
    [ "$DEBUG" -eq 1 ] && return 0
    _label=$1
    _mode=$2
    _watch=${3:-}
    # Plain mode cannot see a passphrase prompt coming: with a key that may
    # ask for one, it stays off, see above.
    [ "$_mode" = plain ] && [ "$KEY_MAY_PROMPT" -eq 1 ] && return 0
    {
        while :; do
            for frame in '|' '/' '-' "\\"; do
                # $$ is still the PID of the script in this subshell. If
                # the script dies without going through its traps, kill -9
                # for instance, the spinner sees it within a frame and
                # stops, instead of drawing forever on the terminal (TD-10).
                kill -0 "$$" 2>/dev/null || exit 0
                if [ "$_mode" = count ]; then
                    # The two tests stay nested: merged into a single
                    # condition, an empty file would fall into the plain
                    # branch and draw over the passphrase prompt.
                    if [ -s "$_watch" ]; then
                        _n=$("$GREP_BIN" -c . "$_watch" 2>/dev/null || echo 0)
                        printf '\r%s %.55s: %d entries' \
                            "$frame" "$_label" "$_n" >&2
                    fi
                else
                    printf '\r%s %.70s' "$frame" "$_label" >&2
                fi
                # Fractional sleep is not POSIX, but every sleep(1) that
                # matters here (GNU, FreeBSD, macOS, busybox) accepts it.
                "$SLEEP_BIN" 0.2
            done
        done
    } &
    SPINNER_PID=$!
    return 0
}

spin_stop() {
    [ -n "$SPINNER_PID" ] || return 0
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r%78s\r' '' >&2 || true
    return 0
}

# stdbuf forces tarsnap to flush its output line by line instead of first
# filling a 4 kB stdio buffer: without it, the counter of the spinner
# would jump from zero to the total in one go. Where it is missing
# (macOS, for instance), the script falls back to the plain spinner.
if [ -x "$STDBUF_BIN" ]; then
    SPIN_MODE=count
else
    SPIN_MODE=plain
fi

###############################################################################
# STEP 1: LISTING THE ARCHIVE
###############################################################################

say "Listing the archive ${SNAPSHOT_NAME}."
: > "$ARCHIVE_RAW"
rc=0
spin_start "listing $SNAPSHOT_NAME" "$SPIN_MODE" "$ARCHIVE_RAW"
if [ "$SPIN_MODE" = count ]; then
    # shellcheck disable=SC2086
    LC_ALL=en_US.UTF-8 TZ=UTC0 "$STDBUF_BIN" -oL "$TARSNAP_BIN" $TARSNAP_KEYOPT \
        --no-config-exclude --no-config-include --numeric-owner -tv --iso-dates \
        -f "$SNAPSHOT_NAME" > "$ARCHIVE_RAW" || rc=$?
else
    # shellcheck disable=SC2086
    LC_ALL=en_US.UTF-8 TZ=UTC0 "$TARSNAP_BIN" $TARSNAP_KEYOPT \
        --no-config-exclude --no-config-include --numeric-owner -tv --iso-dates \
        -f "$SNAPSHOT_NAME" > "$ARCHIVE_RAW" || rc=$?
fi
spin_stop
if [ "$rc" -ne 0 ]; then
    die "\"tarsnap -tv -f $SNAPSHOT_NAME\" failed (exit code $rc), see its message above"
fi

###############################################################################
# STEP 2: NORMALISING THE TWO INVENTORIES
###############################################################################
#
# Both sides produce the same format, four tab-separated fields: relative
# path, type, size, modification date.
#
# The date remains a STRING "YYYY-MM-DD HH:MM:SS" and is never converted
# to an epoch. This is the performance point of the script. "tarsnap -tv
# --iso-dates" and "find -printf '%TY-%Tm-%Td %TH:%TM:%TS'" both yield the
# time in this format, apart from the fractional seconds that find adds
# and that we truncate at the dot, and both run with TZ=UTC0: in local
# time, the hour repeated when the clocks go back prints t and t + 3600 s
# the same, and a file of the same size rewritten one hour later would
# pass for identical (N-R2-13). Comparing the strings therefore gives the
# same verdict as comparing epochs, without calling date.
#
# The previous version forked one "date -d" per archive entry. Measured:
# 0.74 ms per fork on x86, several times more on ARM. Over the 50,000
# entries of a real machine, that took this step from a few seconds to
# several minutes of pure forking, for an identical result.

# One pattern per element of BACKUP_EXCLUDE, same logic as tarsnap-backup.sh.
# Absolute path: anchored, on the path itself as on everything it contains.
# Globbed pattern: passed as is to a case.
is_excluded() {
    # tarsnap -c matches exclusions against the full disk path, leading
    # "/" included (tar/write.c:808), before stripping it (write.c:988).
    # Patterns starting with "/" or "*" are anchored there, the others
    # are tried at every path component; FNM_LEADING_DIR on the right
    # (tar/matching.c, match_exclusion()).
    _abs="/$1"
    for _pat in $BACKUP_EXCLUDE $CONF_EXCLUDE; do
        case "$_pat" in
            /*|\**)
                # shellcheck disable=SC2254
                case "$_abs" in
                    $_pat|$_pat/*) return 0 ;;
                esac
                ;;
            *)
                # shellcheck disable=SC2254
                case "$_abs" in
                    */$_pat|*/$_pat/*) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# Names of the listing come escaped by tarsnap, in bsdtar_expand_char() of
# tar/util.c: a backslash is doubled, \a \b \f \n \r \t \v stand for those
# control characters, and any other byte that is not printable, such as a
# byte of an invalid UTF-8 sequence, becomes three octal digits. find
# writes the raw bytes, so the escapes are undone here, once, through
# printf %b, after \ooo has been turned into \0ooo, the form %b reads
# (TD-05). The doubled backslashes are first set aside under SOH, a byte
# that tarsnap never prints raw, so that the test for a newline or a tab
# only sees real escapes. Returns 1, printing nothing, for such a name: the
# inventories are lines of tab-separated fields, and these names are
# counted apart (N-R1-1).
unescape() {
    case "$1" in
        *\\*) ;;
        *) printf '%s\n' "$1"; return 0 ;;
    esac
    _ue=$(printf '%s\n' "$1" | LC_ALL=C "$SED_BIN" -e "s/\\\\\\\\/$SOH/g" \
        -e 's/\\\([01234567][01234567][01234567]\)/\\0\1/g')
    case "$_ue" in
        *'\n'*|*'\t'*|*'\0012'*|*'\0011'*) return 1 ;;
    esac
    while :; do
        case "$_ue" in
            *"$SOH"*) _ue="${_ue%%"$SOH"*}\\\\${_ue#*"$SOH"}" ;;
            *) break ;;
        esac
    done
    printf '%b\n' "$_ue"
}

# Is the entry under one of the directories of BACKUP_DIRS, as they stand
# today? An entry from a directory removed from BACKUP_DIRS since the
# snapshot is not reported as deleted, but counted apart (N-R3-1). "/"
# covers everything; its own entry is named "." on both sides.
in_dirs() {
    for _d in $BACKUP_DIRS; do
        _r=${_d#/}
        [ -n "$_r" ] || return 0
        case "$1" in
            "$_r"|"$_r"/*) return 0 ;;
        esac
    done
    return 1
}

say "Normalising the archive listing."
skipped_a=0
outside=0
lineno=0
# The redirection applies to the BLOCK, not to each printf: one ">>" per
# line would reopen the file for each of the 50,000 entries. Descriptor 6
# receives the size of every regular file, before any filter, for the hard
# links; descriptor 7 receives the hard links themselves.
#
# Each line is read whole, then split by set --, which set -f keeps from
# globbing: --numeric-owner leaves no blank in the owner and group fields,
# so the eight fields stay in place, even for a group such as "domain
# users" (N-R1-10, TD-16). The name is what follows the date and the time,
# taken from the line itself so that its blanks are kept; " -> " is only
# cut for a symbolic link, and " link to " only for a hard link. The line
# number goes along, for the duplicates of step 4.
{
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # The fields have to be split on blanks, and set -f rules out
        # globbing.
        # shellcheck disable=SC2086
        set -- $line
        [ $# -ge 8 ] || continue
        perm=$1; size=$5; fdate=$6; ftime=$7
        name=${line#*" $fdate $ftime "}
        # First character of the permissions field, without forking
        # cut(1): everything but the first character is removed by
        # expansion.
        type=${perm%"${perm#?}"}
        target=""
        case "$type" in
            -|d) ;;
            l) name=${name%% -> *} ;;
            h) target=${name#* link to }; name=${name%% link to *} ;;
            *) continue ;;   # devices, sockets, pipes: not relevant here
        esac
        # The listing also appends a "/" to directories, find does not: we
        # align the two keys. The root, "./" or "/", becomes ".".
        name=${name%/}
        [ -n "$name" ] || name=.
        if ! name=$(unescape "$name"); then
            skipped_a=$((skipped_a + 1))
            continue
        fi
        if [ "$type" = - ]; then
            printf '%s\t%s\n' "$name" "$size" >&6
        fi
        if ! in_dirs "$name"; then
            outside=$((outside + 1))
            continue
        fi
        is_excluded "$name" && continue
        if [ "$type" = h ]; then
            target=$(unescape "$target") || target=""
            printf '%s\t%s\t%s %s\t%s\n' "$name" "${target:-?}" "$fdate" "$ftime" "$lineno" >&7
            continue
        fi
        printf '%s\t%s\t%s\t%s %s\t%s\n' "$name" "$type" "$size" "$fdate" "$ftime" "$lineno"
    done < "$ARCHIVE_RAW"
} > "$ARCHIVE_META" 6> "$ARCHIVE_FILES" 7> "$HARD_RAW"

# A hard link is listed with a size of 0 and the name of its target, an
# entry of type "-" listed before it: tarsnap only links to an entry it
# has already written. The link takes the size of that target, then
# counts as the regular file that find sees under its own name; a target
# that cannot be found leaves the size unknown, hence a verdict "*". The
# list of the links stays for step 5c, which extracts their targets with
# them (TD-04).
LC_ALL=C "$SORT_BIN" -t "$TAB" -k2,2 "$HARD_RAW" -o "$HARD_RAW"
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -u "$ARCHIVE_FILES" -o "$ARCHIVE_FILES"
LC_ALL=C "$JOIN_BIN" -t "$TAB" -1 2 -2 1 -a 1 -e '?' -o 1.1,0,2.2,1.3,1.4 \
    "$HARD_RAW" "$ARCHIVE_FILES" > "$HARD_LIST"
while IFS="$TAB" read -r name target size stamp lno; do
    printf '%s\t-\t%s\t%s\t%s\n' "$name" "$size" "$stamp" "$lno"
done < "$HARD_LIST" >> "$ARCHIVE_META"

if [ "$outside" -gt 0 ]; then
    printf 'WARNING: %s entries of the snapshot lie outside the current BACKUP_DIRS, ignored\n' \
        "$outside" >&2
fi

###############################################################################
# STEP 3: CURRENT STATE OF THE FILE SYSTEM
###############################################################################

# The walk covers what tarsnap -c archives, and nothing more (N-GAP2-2):
# - the cache directory of tarsnap stays out, as tarsnap leaves it out
#   (tar/write.c:958-968), and so do the temporary directory and the
#   working file of this script (N-GAP2-3);
# - unless tarsnap.conf has insane-filesystems, the mount point of a
#   synthetic file system crossed during the walk is listed but not
#   entered, as tar/write.c:871-896 does, for the Linux types of
#   synthetic_filesystems[] in lib-platform/util/ts_getfstype.c. A
#   directory of BACKUP_DIRS that lies itself on such a file system is
#   entered: tarsnap only checks the file systems that it crosses, the one
#   of the starting point being accepted from the outset (tar/write.c:863);
# - a name holding a newline or a tab stays out, with everything below it,
#   and is counted: the inventory is made of lines of tab-separated fields,
#   where such a name could forge or hide entries (N-R1-1);
# - -ignore_readdir_race, and errors of find give a warning instead of
#   stopping the diff after the listing (N-R2-8).
# The command is built in the positional parameters, which nothing needs
# any more at this point.
CACHE_DIR=""
INSANE_FS=0
if _cd_dump=$("$TARSNAP_BIN" --dump-config 2>&1 >/dev/null); then
    CACHE_DIR=$(printf '%s\n' "$_cd_dump" | "$SED_BIN" -n \
        -e '1,/^Reading from config file: /d' \
        -e '/^  cachedir[[:space:]]/!d' \
        -e 's/^  cachedir[[:space:]]*//p' -e 'q')
    case "$_cd_dump" in
        *"$NL  insane-filesystems$NL"*|*"$NL  insane-filesystems") INSANE_FS=1 ;;
    esac
fi
case "$CACHE_DIR" in
    /*) CACHE_DIR=$(CDPATH='' cd -P -- "$CACHE_DIR" 2>/dev/null && pwd -P) || CACHE_DIR="" ;;
    *)  CACHE_DIR="" ;;
esac
dbg "CACHE_DIR=$CACHE_DIR INSANE_FS=$INSANE_FS"
FIND_FMT='%y\t%s\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\n'
FIND_ERRORS=""

say "Walking the file system."
: > "$LOCAL_RAW"
for dir in $BACKUP_DIRS; do
    if [ ! -e "$dir" ]; then
        printf 'WARNING: BACKUP_DIRS directory missing, skipped: %s\n' \
            "$(ctl_safe "$dir")" >&2
        continue
    fi
    set -- "$dir" -ignore_readdir_race \( -path "$TMP_DIR" -o -path "$LOGFILE_WORK"
    if [ -n "$CACHE_DIR" ]; then
        set -- "$@" -o -path "$CACHE_DIR"
    fi
    set -- "$@" \) -prune -o \( -name "*$NL*" -o -name "*$TAB*" \) -printf '!\n' -prune -o
    if [ "$INSANE_FS" -eq 0 ]; then
        # The type of the file system of the starting point, which is not
        # crossed, leaves the list.
        _start_fs=$("$FIND_BIN" "$dir" -maxdepth 0 -printf '%F' 2>/dev/null) \
            || _start_fs=""
        set -- "$@" \(
        _first=1
        for _fs in proc sysfs devpts securityfs selinuxfs usbfs devfs; do
            [ "$_fs" != "$_start_fs" ] || continue
            if [ "$_first" -eq 1 ]; then
                _first=0
            else
                set -- "$@" -o
            fi
            set -- "$@" -fstype "$_fs"
        done
        set -- "$@" \) -printf "$FIND_FMT" -prune -o
    fi
    set -- "$@" -printf "$FIND_FMT"
    _frc=0
    TZ=UTC0 "$FIND_BIN" "$@" >> "$LOCAL_RAW" || _frc=$?
    if [ "$_frc" -ne 0 ]; then
        printf 'WARNING: find reported errors under %s, the inventory may be incomplete\n' \
            "$(ctl_safe "$dir")" >&2
        FIND_ERRORS="${FIND_ERRORS:+$FIND_ERRORS }$dir"
    fi
done
skipped_l=0

{
    # IFS forced to the tab, and not the default IFS: the date field
    # contains a space between the day and the time, which the default
    # splitting would take for a field separator. As a corollary, a file
    # name containing a tab would break this format; it would break join
    # anyway as well, which works on the same columns.
    while IFS="$TAB" read -r ftype fsize fstamp fpath; do
        if [ "$ftype" = '!' ]; then
            skipped_l=$((skipped_l + 1))
            continue
        fi
        [ -n "${fpath:-}" ] || continue
        case "$ftype" in
            f) type=- ;;
            d) type=d ;;
            l) type=l ;;
            *) continue ;;
        esac
        # tarsnap strips the leading "/" from entry names, except with -P:
        # both inventories must carry the same key, so it is removed on
        # this side too.
        name=${fpath#/}
        [ -n "$name" ] || name=.
        is_excluded "$name" && continue
        # find yields the seconds with their fractional part
        # ("22:43:01.7108968160"), which tarsnap does not print: we
        # truncate at the dot.
        printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$fsize" "${fstamp%%.*}"
    done < "$LOCAL_RAW"
} > "$LOCAL_META"

if [ "$skipped_a" -gt 0 ] || [ "$skipped_l" -gt 0 ]; then
    printf 'WARNING: names holding a newline or a tab left out: %s in the snapshot, %s on the system\n' \
        "$skipped_a" "$skipped_l" >&2
fi

###############################################################################
# STEP 4: MATCHING THE TWO INVENTORIES
###############################################################################
#
# LC_ALL=C on sort AND on join: join misbehaves, silently, if the
# collation order of its inputs is not the one it uses itself.
#
# The "-u" applies to the key alone and guards against a duplicate path:
# two BACKUP_DIRS entries overlapping on the system side, or an archive
# containing the same path twice, which tarsnap allows. Without it, join
# would produce the Cartesian product of the duplicates. On the archive
# side, the last occurrence is kept, the one that tarsnap -x restores: a
# sort by name then by descending line number, then a stable "-u", before
# the line number is dropped (N-R2-15).

say "Matching the two inventories."
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -k5,5nr "$ARCHIVE_META" -o "$ARCHIVE_META"
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -u -s "$ARCHIVE_META" -o "$ARCHIVE_META"
"$SED_BIN" -i "s/${TAB}[^${TAB}]*\$//" "$ARCHIVE_META"
LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 -u "$LOCAL_META"   -o "$LOCAL_META"

# By default, join joins on the first field of each file, which is
# exactly our case: no need to specify -1 and -2.
LC_ALL=C "$JOIN_BIN" -t "$TAB" -v 1 "$ARCHIVE_META" "$LOCAL_META" > "$DELETED_LIST"
LC_ALL=C "$JOIN_BIN" -t "$TAB" -v 2 "$ARCHIVE_META" "$LOCAL_META" > "$NEW_LIST"
LC_ALL=C "$JOIN_BIN" -t "$TAB"      "$ARCHIVE_META" "$LOCAL_META" > "$COMMON_LIST"

###############################################################################
# STEP 5: LOG
###############################################################################

# The detail lines go to descriptor 3, opened on the working file of the
# log when it was created, and kept open until the end. Each line
# therefore reaches it immediately, with no intermediate buffer, and a
# "tail -f" of that file from another terminal sees the diff being built
# instead of waiting for the script to return.
#
# Only the detail lines go through it. The header, which carries the four
# counters, is put in front of them in step 6, once those are known.

log() {
    ctl_safe "$*" >&3
}

del_count=0
new_count=0
id_count=0
mod_count=0
cand_count=0

# Deleted and new: immediate verdict, no network access. They go to the
# log right away, before the slow phase, so that a "tail -f" has
# something to read from the very first seconds.
while IFS="$TAB" read -r path _type _size _stamp; do
    [ -n "$path" ] || continue
    del_count=$((del_count + 1))
    [ "$SHOW_DELETED" -eq 1 ] && log "< ${path}"
done < "$DELETED_LIST"

while IFS="$TAB" read -r path _type _size _stamp; do
    [ -n "$path" ] || continue
    new_count=$((new_count + 1))
    [ "$SHOW_NEW" -eq 1 ] && log "> ${path}"
done < "$NEW_LIST"

say "$del_count deleted, $new_count new."

###############################################################################
# STEP 5b: TRIAGE OF THE COMMON FILES
###############################################################################
#
# First pass, entirely local: everything that can be settled without the
# network is settled, and only the genuinely ambiguous cases are set
# aside. The certain verdicts are logged as they come.
#
# The redirection applies to the block, which does NOT create a subshell
# in POSIX sh, unlike a pipeline: the counters incremented here do survive
# the closing of the block. Verified under dash and under bash.

say "Classifying the common files."
{
    while IFS="$TAB" read -r path type_a size_a stamp_a type_l size_l stamp_l; do
        [ -n "$path" ] || continue

        # The same name with another type on each side, a file that became
        # a directory or a symbolic link for instance: modified, at once.
        # Neither the sizes nor cmp, which follows links, would mean
        # anything here (TD-03).
        if [ "$type_a" != "$type_l" ]; then
            mod_count=$((mod_count + 1))
            [ "$SHOW_MODIFIED" -eq 1 ] && log "* ${path}"
            continue
        fi

        # Directories and links: their mere presence on both sides counts
        # as identical, see the limitations at the top of the script.
        if [ "$type_a" != "-" ]; then
            id_count=$((id_count + 1))
            [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}"
            continue
        fi

        # Strict mode sends everything to the download, unless there is
        # nothing to tell apart anyway.
        if [ "$STRICT" -eq 0 ] || [ "$NEED_BYTE_CHECK" -eq 0 ]; then
            if [ "$size_a" != "$size_l" ]; then
                # Different sizes: the content necessarily differs, no
                # reason to pay for a download to confirm it.
                mod_count=$((mod_count + 1))
                [ "$SHOW_MODIFIED" -eq 1 ] && log "* ${path}"
                continue
            fi
            if [ "$stamp_a" = "$stamp_l" ]; then
                # Size and mtime match: identical, by heuristic.
                id_count=$((id_count + 1))
                [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}"
                continue
            fi
        fi

        # What remains is the ambiguous case.
        if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
            # Neither -i nor -m requested: the download would only serve
            # to tell apart two categories you want to know nothing about.
            # We stick to the metadata verdict, which can only be
            # "modified" since the mtime differs. The counter is therefore
            # indicative, and the log says so.
            mod_count=$((mod_count + 1))
            continue
        fi

        cand_count=$((cand_count + 1))
        printf '%s\n' "$path"
    done < "$COMMON_LIST"
} > "$CANDIDATES"

if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    say "Download short-circuited: neither -i nor -m requested, nothing to tell apart."
else
    say "$cand_count file(s) to check byte by byte."
fi

###############################################################################
# STEP 5c: BYTE-BY-BYTE CHECK OF THE AMBIGUOUS CASES
###############################################################################

EXTRACT_FAILED=0
if [ "$cand_count" -gt 0 ]; then
    "$MKDIR_BIN" -p "$EXTRACT_DIR"

    # tarsnap -x reads each line of -T as a pattern, glob characters and
    # backslash included (fnmatch(3) with FNM_LEADING_DIR): a name holding
    # "*", "?", "[" or a backslash would extract other files, or nothing
    # at all. tarsnap therefore gets an escaped copy of the list (N-R1-9,
    # TD-15), to which the target of every hard link among the candidates
    # is added: tarsnap can only recreate a link next to its target
    # (TD-04). A target that step 2 could not find, written "?", is left
    # out: the link will not be downloaded, and its verdict will say so.
    LC_ALL=C "$SORT_BIN" -t "$TAB" -k1,1 "$HARD_LIST" -o "$HARD_BY_NAME"
    {
        "$CAT_BIN" "$CANDIDATES"
        LC_ALL=C "$JOIN_BIN" -t "$TAB" -o 1.2 "$HARD_BY_NAME" "$CANDIDATES" \
            | "$GREP_BIN" -v -x -F '?' || true
    } | LC_ALL=C "$SED_BIN" 's/[][*?\\]/\\&/g' | LC_ALL=C "$SORT_BIN" -u > "$PATTERNS"

    # A SINGLE tarsnap invocation for the whole list. The -T option reads
    # the names from a file and -C places the extraction in the temporary
    # directory. One invocation per file would reopen the archive on the
    # server side every time, which made the previous version unusable
    # from a hundred files onwards.
    say "Downloading $cand_count file(s) from the snapshot."
    rc=0
    spin_start "downloading $cand_count file(s)" plain
    if [ "$KEY_MAY_PROMPT" -eq 1 ]; then
        # Key that may ask for a passphrase: the stderr of tarsnap stays on
        # the terminal. Redirected to TARSNAP_ERR, it would take the prompt
        # along, and tarsnap would wait for the answer to a question that
        # nobody can see.
        # shellcheck disable=SC2086
        LC_ALL=en_US.UTF-8 "$TARSNAP_BIN" $TARSNAP_KEYOPT --no-config-exclude \
            --no-config-include --no-same-owner --no-same-permissions \
            -x -C "$EXTRACT_DIR" -f "$SNAPSHOT_NAME" -T "$PATTERNS" || rc=$?
    else
        # shellcheck disable=SC2086
        LC_ALL=en_US.UTF-8 "$TARSNAP_BIN" $TARSNAP_KEYOPT --no-config-exclude \
            --no-config-include --no-same-owner --no-same-permissions \
            -x -C "$EXTRACT_DIR" -f "$SNAPSHOT_NAME" -T "$PATTERNS" \
            2> "$TARSNAP_ERR" || rc=$?
    fi
    spin_stop
    # A failed extraction may have left partial copies behind, a file cut
    # short or filled with zeros: none of them is compared, and all the
    # candidates are reported as modified, a cautious verdict that the
    # header of the log explains (N-R2-14).
    if [ "$rc" -ne 0 ]; then
        EXTRACT_FAILED=$rc
        printf 'WARNING: "tarsnap -x" returned %s: a copy may be partial, so none is\n' "$rc" >&2
        printf '         compared, and the %s file(s) to check are reported as modified.\n' \
            "$cand_count" >&2
        if [ "$KEY_MAY_PROMPT" -eq 1 ]; then
            printf '         See the message from tarsnap above.\n' >&2
        else
            printf '         Message from tarsnap:\n' >&2
            "$SED_BIN" 's/^/  /' "$TARSNAP_ERR" >&2
        fi
    fi

    say "Byte-by-byte comparison."
    {
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            if [ "$EXTRACT_FAILED" -ne 0 ]; then
                printf '*\t%s\n' "$path"
                continue
            fi
            # cmp follows symbolic links: a copy or a file that is not, or
            # no longer, a regular file is not compared (TD-03).
            if [ -h "/$path" ] || [ ! -f "/$path" ]; then
                printf 'WARNING: no longer a regular file, verdict forced to "modified": %s\n' \
                    "$(ctl_safe "$path")" >&2
                printf '*\t%s\n' "$path"
                continue
            fi
            if [ -h "$EXTRACT_DIR/$path" ] || { [ -e "$EXTRACT_DIR/$path" ] &&
                    [ ! -f "$EXTRACT_DIR/$path" ]; }; then
                printf 'WARNING: extracted as something other than a regular file, verdict forced to "modified": %s\n' \
                    "$(ctl_safe "$path")" >&2
                printf '*\t%s\n' "$path"
                continue
            fi
            if [ ! -e "$EXTRACT_DIR/$path" ]; then
                # Not downloaded: nothing can be asserted, so we take good
                # care not to claim that it is identical. Cautious verdict.
                printf 'WARNING: not downloaded, verdict forced to "modified": %s\n' \
                    "$(ctl_safe "$path")" >&2
                printf '*\t%s\n' "$path"
                continue
            fi
            # Classic pitfall under set -e: in "if cmd; then X; fi", when
            # cmd fails and there is no else branch, $? after the fi is 0
            # per the POSIX specification, and not the status of cmd.
            # Hence the explicit else, the only place where $? still
            # faithfully reflects the exit status of cmp.
            if "$CMP_BIN" -s "$EXTRACT_DIR/$path" "/$path"; then
                _rc=0
            else
                _rc=$?
            fi
            case "$_rc" in
                0) printf '=\t%s\n' "$path" ;;
                1) printf '*\t%s\n' "$path" ;;
                *) printf 'WARNING: cmp returned %s, verdict forced to "modified": %s\n' \
                       "$_rc" "$(ctl_safe "$path")" >&2
                   printf '*\t%s\n' "$path" ;;
            esac
        done < "$CANDIDATES"
    } > "$VERDICTS"

    while IFS="$TAB" read -r verdict path; do
        [ -n "$path" ] || continue
        case "$verdict" in
            '=') id_count=$((id_count + 1))
                 [ "$SHOW_IDENTICAL" -eq 1 ] && log "= ${path}" ;;
            '*') mod_count=$((mod_count + 1))
                 [ "$SHOW_MODIFIED" -eq 1 ] && log "* ${path}" ;;
        esac
    done < "$VERDICTS"
fi

###############################################################################
# STEP 6: SUMMARY
###############################################################################

# The header could not be written earlier: it carries the four counters,
# which are only known here. It is therefore written in a second working
# file, followed by the details read back through descriptor 4, and that
# file is renamed onto the log.
#
# Next to the log, and not in TMP_DIR: rename(2) does not cross file
# systems, and TMP_DIR lives under /tmp, which is very often elsewhere. The
# local rename is atomic, so the log is never left truncated, even if the
# machine goes down during the operation. -T makes mv replace whatever
# entry holds the name of the log at that moment, rather than move the file
# into a directory that a symbolic link would point to (TD-06).
exec 3>&-

# mktemp rather than a name derived from the PID: with -l pointing into a
# directory that everyone can write to, /tmp for instance, a predictable
# name could be planted beforehand, as a symbolic link or as a file owned
# by someone else. mktemp creates the file itself, under a random name and
# with O_EXCL, in mode 0600: the log keeps that mode once renamed.
LOGFILE_TMP=$("$MKTEMP_BIN" "${LOGFILE}.XXXXXXXX") \
    || die "cannot create a working file next to the log: $LOGFILE"

{
    printf '# %s\n'                    "${0##*/}"
    printf '# snapshot    : %s\n'      "$SNAPSHOT_NAME"
    printf '# date        : %s\n'      "$STARTED_AT"
    printf '# directories : %s\n'      "$BACKUP_DIRS"
    printf '# exclusions  : %s\n'      "$BACKUP_EXCLUDE"
    if [ "$EXTRACT_FAILED" -ne 0 ]; then
        printf '# extraction  : tarsnap -x failed (exit code %s), no copy compared,\n' "$EXTRACT_FAILED"
        printf '#               the files to check are reported as modified\n'
    fi
    if [ -n "$CONF_EXCLUDE" ]; then
        printf '# tarsnap.conf: %s\n'      "$CONF_EXCLUDE"
    fi
    if [ "$skipped_a" -gt 0 ] || [ "$skipped_l" -gt 0 ]; then
        printf '# skipped     : %s in the snapshot, %s on the system, names holding a newline or a tab\n' \
            "$skipped_a" "$skipped_l"
    fi
    if [ "$outside" -gt 0 ]; then
        printf '# outside dirs: %s entries of the snapshot outside BACKUP_DIRS\n' "$outside"
    fi
    if [ -n "$FIND_ERRORS" ]; then
        printf '# find errors : %s\n'      "$FIND_ERRORS"
    fi
    if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
        printf '# mode        : metadata only, since neither -i nor -m was requested\n'
        printf '#               no download, so the = and * counters are only\n'
        printf '#               indicative: they were not verified byte by byte\n'
    elif [ "$STRICT" -eq 1 ]; then
        printf '# mode        : strict, byte-by-byte comparison of all the common files\n'
    else
        printf '# mode        : hybrid, byte by byte if equal size and different mtime\n'
    fi
    printf '#\n'
    printf '# deleted    (<) : %s\n'   "$del_count"
    printf '# new        (>) : %s\n'   "$new_count"
    printf '# identical  (=) : %s\n'   "$id_count"
    printf '# modified   (*) : %s\n'   "$mod_count"
    "$CAT_BIN" <&4
} > "$LOGFILE_TMP" || die "cannot write: $LOGFILE_TMP"
exec 4<&-

"$MV_BIN" -fT "$LOGFILE_TMP" "$LOGFILE" || die "cannot rename: $LOGFILE_TMP"
LOGFILE_TMP=""
"$RM_BIN" -f "$LOGFILE_WORK"
LOGFILE_WORK=""

printf 'Diff of %s\n\n' "$SNAPSHOT_NAME"
printf '  deleted     (<) : %s\n' "$del_count"
printf '  new         (>) : %s\n' "$new_count"
if [ "$NEED_BYTE_CHECK" -eq 0 ]; then
    # Without -i or -m, these two counters come from the metadata alone:
    # we do not present them as if they had been verified.
    printf '  identical   (=) : %s  (indicative, not verified)\n' "$id_count"
    printf '  modified    (*) : %s  (indicative, not verified)\n' "$mod_count"
else
    printf '  identical   (=) : %s\n' "$id_count"
    printf '  modified    (*) : %s\n' "$mod_count"
fi
printf '  --------------------------------\n'
printf '  total           : %s\n\n' \
    "$((del_count + new_count + id_count + mod_count))"
printf 'Details: %s\n' "$LOGFILE"

exit 0
