#!/bin/sh
#
# TD-01: under set -x, --debug of tarsnap-diff.sh, the trace showed the
# passphrase of an env: method. passphrase_reachable() only expands
# ${NAME:+x}: neither the trace of tarsnap-diff.sh --debug nor that of
# tarsnap-backup.sh run under sh -x shows the value.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
key_protected "$T/tarsnap.key"
set_conf_str TARSNAP_PASSPHRASE "env:TSPP"
install_diff
snapshot snap1 "$T/root"
TSPP=S3cr3t-Pass
export TSPP

SHELL_OPTS=-x
run_backup
SHELL_OPTS=""
expect_rc 0 "backup under -x"
expect_err "_pp_set=x"
reject_err S3cr3t-Pass

run_diff --debug snap1
expect_rc 0 "diff --debug"
expect_err "_pp_set=x"
reject_err S3cr3t-Pass

t_done
