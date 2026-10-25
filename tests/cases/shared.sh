#!/bin/sh
#
# Shared functions: each pair listed under Invariants in HACKING.md keeps
# the same body, byte for byte, check_max_purge() included. Any other
# function defined under the same name in two scripts is either known to
# differ, or reported: a new copy has to be declared on one side or the
# other.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init

# Name, then the two scripts that hold it.
SHARED="key_is_passphrased:tarsnap-backup.sh:tarsnap-diff.sh
passphrase_reachable:tarsnap-backup.sh:tarsnap-diff.sh
conf_keyfile:tarsnap-backup.sh:tarsnap-diff.sh
check_dirs:tarsnap-backup.sh:tarsnap-diff.sh
check_excludes:tarsnap-backup.sh:tarsnap-diff.sh
check_retention:tarsnap-backup.sh:rotation-check.sh
check_max_purge:tarsnap-backup.sh:rotation-check.sh
shown:tarsnap-backup.sh:rotation-check.sh"

# Same name, a body of its own in each script, on purpose.
DIFFERENT="usage die say cleanup spin_start spin_stop shown"

body() {
    sed -n "/^$1() {\$/,/^}/p" "$REPO_DIR/$2"
}

for t in $SHARED; do
    fn=${t%%:*}
    files=${t#*:}
    a=${files%%:*}
    b=${files#*:}
    x=$(body "$fn" "$a")
    y=$(body "$fn" "$b")
    if [ -z "$x" ] || [ -z "$y" ]; then
        fail "$fn missing in $a or in $b"
    elif [ "$x" != "$y" ]; then
        fail "$fn differs between $a and $b"
    fi
done

# Every name defined in two scripts or more: shared, or known to differ.
for f in tarsnap-backup.sh rotation-check.sh tarsnap-diff.sh tarsnap-stats.sh; do
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {$/\1/p' "$REPO_DIR/$f"
done | LC_ALL=C sort | uniq -d > "$T/twice"
while IFS= read -r fn; do
    case " $DIFFERENT " in
        *" $fn "*) continue ;;
    esac
    case "$SHARED" in
        "$fn:"*|*"
$fn:"*) continue ;;
    esac
    fail "$fn is defined in two scripts, neither shared nor known to differ"
done < "$T/twice"

t_done
