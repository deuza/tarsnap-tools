#!/bin/sh
#
# N-R1-14: the messages about an invalid TARSNAP_PASSPHRASE repeated its
# value, which may be the passphrase itself, written there by mistake, and
# which then went into the cron mail. Neither tarsnap-backup.sh nor
# tarsnap-diff.sh shows it any more.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
install_diff
CONF="$T/usr/local/sbin/tarsnap-backup.sh"

# refused VALUE SECRET BACKUP-MESSAGE DIFF-MESSAGE
refused() {
    set_conf_str TARSNAP_PASSPHRASE "$1"
    run_backup
    expect_rc 1 "backup, $1"
    expect_err "ERROR: $3"
    reject_err "$2"
    run_diff snap1
    expect_rc 1 "diff, $1"
    expect_err "ERROR: $4"
    reject_err "$2"
}

refused "pass:hunter2" hunter2 \
    "invalid TARSNAP_PASSPHRASE, see the configuration block (value not shown)" \
    "invalid TARSNAP_PASSPHRASE, see $CONF (value not shown)"
refused "correct horse" horse \
    "TARSNAP_PASSPHRASE must not contain whitespace (value not shown)" \
    "TARSNAP_PASSPHRASE must not contain whitespace, see $CONF (value not shown)"
refused "env:A-B" A-B \
    "invalid variable name in TARSNAP_PASSPHRASE (value not shown)" \
    "invalid variable name in TARSNAP_PASSPHRASE, see $CONF (value not shown)"

t_done
