#!/bin/sh
#
# N-R5-1: with an env: passphrase, the variable that holds it reached
# every command of the hooks, and a hook that changed user kept it in a
# process anyone of that user could read. run_hook() unsets it in the
# subshell of the hook; the script itself still checked it.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
key_protected "$T/tarsnap.key"
set_conf_str TARSNAP_PASSPHRASE "env:TSPP"
cat > "$T/pre.sh" <<HOOK
printf '%s\n' "\${TSPP-unset}" > "$T/hookvar"
env > "$T/hookenv"
HOOK
add_hook prebackup "$T/pre.sh"
TSPP=S3cr3t-Pass
export TSPP

run_backup
expect_rc 0
[ "$(cat "$T/hookvar")" = unset ] || fail "the hook sees the variable of env:"
if grep -qF S3cr3t-Pass "$T/hookenv"; then
    fail "the passphrase is in the environment of the hook"
fi

t_done
