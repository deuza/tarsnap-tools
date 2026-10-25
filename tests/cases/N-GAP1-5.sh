#!/bin/sh
#
# N-GAP1-5: neither the configured script nor its retention values were
# backed up. /usr/local/sbin, where it is installed, is part of the
# shipped BACKUP_DIRS, read here from the script without running it.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
dirs=$(sed -n 's/^BACKUP_DIRS="\([^"]*\)".*/\1/p' "$REPO_DIR/tarsnap-backup.sh")
case " $dirs " in
    *" /usr/local/sbin "*) ;;
    *) fail "/usr/local/sbin is not in the shipped BACKUP_DIRS: $dirs" ;;
esac

t_done
