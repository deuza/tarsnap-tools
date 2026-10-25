#!/bin/sh
#
# TB-07: an absolute exclusion lost its leading / on the way to tarsnap,
# which then tried it at every level of the tree and excluded any
# directory of the same name further down. The pattern now reaches tarsnap
# as written, anchored at the root, its trailing slash removed.
#
# With -t, the same configuration goes through a real tarsnap -c --dry-run:
# the excluded directory is left out, a look-alike further down is kept.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
set_conf_str BACKUP_EXCLUDE "$T/root/data/APOD */tmp/* $T/root/www/"

run_backup
expect_rc 0
expect_arg c "--exclude=$T/root/data/APOD"
expect_arg c "--exclude=$T/root/data/APOD/*"
expect_arg c "--exclude=*/tmp/*"
expect_arg c "--exclude=$T/root/www"
expect_arg c "--exclude=$T/root/www/*"
reject_arg c "--exclude=${T#/}/root/data/APOD"

if group real; then
    mkdir -p "$T/root/data/APOD" "$T/root/mirror$T/root/data/APOD"
    printf 'a\n' > "$T/root/data/APOD/img.jpg"
    printf 'b\n' > "$T/root/data/keep.txt"
    printf 'c\n' > "$T/root/mirror$T/root/data/APOD/img.jpg"
    # The real tarsnap for -c, the stub for the rest; no key, so that
    # tarsnap generates throwaway keys, and no configuration file.
    cat > "$T/bin/tarsnap-real" <<WRAP
#!/bin/sh
for a do
    case "\$a" in
        -c) exec "$TESTS_TARSNAP" --no-default-config "\$@" ;;
    esac
done
exec "$T/bin/tarsnap" "\$@"
WRAP
    chmod +x "$T/bin/tarsnap-real"
    set_conf_str TARSNAP_BIN "$T/bin/tarsnap-real"
    set_conf_str TARSNAP_KEY ""
    set_conf_str BACKUP_EXCLUDE "$T/root/data/APOD"
    run_backup --dry-run --verbose
    expect_rc 0 "real tarsnap"
    expect_err "a ${T#/}/root/data/keep.txt"
    expect_err "a ${T#/}/root/mirror$T/root/data/APOD/img.jpg"
    reject_err "a ${T#/}/root/data/APOD/img.jpg"
fi

t_done
