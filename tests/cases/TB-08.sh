#!/bin/sh
#
# TB-08, with TD-12: under dash, a redirection of exec that fails ends the
# shell before "|| die" can speak, and the message was lost. Both scripts
# now try the opening in a subshell first: the lock of tarsnap-backup.sh,
# the working file of the log of tarsnap-diff.sh.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
set_conf_str LOCK_FILE "$T/run/missing/tarsnap-backup.lock"
run_backup
expect_rc 1 "lock"
expect_err "ERROR: cannot open the lock: $T/run/missing/tarsnap-backup.lock"
expect_no_call

# mktemp creates the working file of the log, then the script opens it: a
# directory in its place makes that opening fail.
install_backup
cat > "$T/bin/mktemp" <<WRAP
#!/bin/sh
case "\$*" in
    *.log.XXXXXXXX)
        d=\$(/usr/bin/mktemp -d "\$1") && printf '%s\n' "\$d"
        exit
        ;;
esac
exec /usr/bin/mktemp "\$@"
WRAP
chmod +x "$T/bin/mktemp"
install_diff -e "s|^MKTEMP_BIN=.*|MKTEMP_BIN=\"$T/bin/mktemp\"|"
snapshot snap1 "$T/root"
run_diff snap1
expect_rc 1 "log of tarsnap-diff.sh"
expect_err "ERROR: log not writable: $T/log/tarsnap-diff.sh-snap1.log."
if [ -e "$T/log/tarsnap-diff.sh-snap1.log" ]; then
    fail "the log was created"
fi

t_done
