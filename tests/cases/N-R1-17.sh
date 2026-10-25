#!/bin/sh
#
# N-R1-17: tarsnap -x restored the owner, the mode and the file flags of
# the snapshot in the temporary directory, an immutable file there made
# the cleanup fail, and a finished diff ended in an error. The extraction
# gets --no-same-owner and --no-same-permissions, and a temporary
# directory that cannot be removed only gives a warning.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
cat > "$T/bin/rm" <<WRAP
#!/bin/sh
case "\$*" in
    *"$T/tmp/tarsnap-diff."*) exit 1 ;;
esac
exec /usr/bin/rm "\$@"
WRAP
chmod +x "$T/bin/rm"
install_diff -e "s|^RM_BIN=.*|RM_BIN=\"$T/bin/rm\"|"
printf 'abc\n' > "$T/root/f"
snapshot snap1 "$T/root"
touch -d '2026-01-02 00:00:00' "$T/root/f"

run_diff snap1
expect_rc 0
expect_calls x 1
for opt in --no-same-owner --no-same-permissions --no-config-exclude \
    --no-config-include; do
    expect_arg x "$opt"
done
expect_err "WARNING: could not remove the temporary directory: $T/tmp/tarsnap-diff."
expect_out "identical   (=) : 2"

t_done
