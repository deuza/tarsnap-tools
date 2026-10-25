#!/bin/sh
#
# N-R4-1: the hooks ran under set -f, so that "rm -f /root/dumps/*.sql"
# removed nothing. run_hook() turns pathname expansion back on for them.

# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
t_init
install_backup
mkdir "$T/dumps"
cat > "$T/pre.sh" <<HOOK
: > "$T/dumps/a.sql"
: > "$T/dumps/b.sql"
set -- "$T"/dumps/*.sql
printf '%s\n' "\$#" > "$T/globbed"
HOOK
cat > "$T/post.sh" <<HOOK
rm -f "$T"/dumps/*.sql
HOOK
add_hook prebackup "$T/pre.sh"
add_hook postbackup "$T/post.sh"

run_backup
expect_rc 0
[ "$(cat "$T/globbed")" = 2 ] || fail "prebackup: no pathname expansion"
for f in "$T"/dumps/*.sql; do
    if [ -e "$f" ]; then
        fail "postbackup removed nothing: $f"
    fi
done

t_done
