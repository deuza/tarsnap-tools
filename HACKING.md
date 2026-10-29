# Hacking on tarsnap-tools

This file is for whoever reads or changes the code. It gathers the rules the scripts follow, the invariants that no change may break, the validation procedure, the ShellCheck directives and the reasons behind the less obvious choices.

Using the suite only requires the [README](README.md).

## Contents

- [Repository layout](#repository-layout)
- [Invariants](#invariants)
- [Configuration read by the companion tools](#configuration-read-by-the-companion-tools)
- [Validation](#validation)
- [ShellCheck directives](#shellcheck-directives)
- [Technical choices](#technical-choices)
- [Passphrase and key detection](#passphrase-and-key-detection)
- [Exclusion matching in Tarsnap](#exclusion-matching-in-tarsnap)
- [The `--dry-run-metadata` bug](#the---dry-run-metadata-bug)

## Repository layout

| File | Role |
|---|---|
| `tarsnap-backup.sh` | backup and rotation, carries the configuration |
| `rotation-check.sh` | replays the rotation logic, never runs Tarsnap |
| `tarsnap-diff.sh` | compares a snapshot with the system, read-only |
| `tarsnap-stats.sh` | sizes, deduplication and cost, also published in its own repository |
| `tests/` | regression suite, see [Regression tests](#regression-tests) |

`tarsnap-stats.sh` is developed here, like the other scripts. Each change is then copied to [deuza/tarsnap-stats](https://github.com/deuza/tarsnap-stats), the repository that tarsnap.com lists among its helper scripts, and committed and pushed there, next to a README of its own, adapted to the script alone.

The scripts are written in strictly POSIX `sh` and run under `dash`, `bash` and `busybox sh`, `posh` excepted (see [Validation](#validation)), but they target Debian on purpose: binaries under `/usr/bin` (`usrmerge`), GNU `date -d` and `%-d`, GNU `find -printf`, and GNU `sed` reading the binary content of a raw key file.

## Invariants

A change that breaks one of these is a regression, whatever it gains elsewhere.

- **Creation before deletion.** The new archive exists before the purge starts, and a failure anywhere before that point deletes nothing.
- **`set -euf`.** Exit on the first error, unset variables are fatal, and no pathname expansion at all: `-f` disables globbing everywhere, patterns written out in full included, not only on unquoted expansions. The hooks get it back, see [Technical choices](#technical-choices). `tarsnap-stats.sh` uses `set -eu`.
- **`umask 077`.** Set right after `set -euf`, before anything is created: the lock, the package inventories and the dumps of `prebackup` are private to root (N-R1-4).
- **`flock` lock on descriptor 9.** The Tarsnap manual forbids two concurrent create or delete operations with the same key, and the lock keeps two runs of this machine from overlapping. It is local to the host: two machines sharing a key are not serialised by it, hence one key per machine (N-GAP1-2). The lock is held by an open descriptor, so the kernel releases it when the process dies, `kill -9`, OOM and power failure included: no stale lock file, and no race between an existence test and a `touch`.
- **Two protections for the lock file.** `/run`, mode 755 and owned by root, reserves the creation and the replacement of the file to root, and the mode 0600 of the file, given by the umask, keeps other users from opening it at all: `flock(2)` also locks a descriptor opened read-only, so a lock readable by all could be held by any local user, blocking the backups (N-R1-5). A lock left in mode 0644 by an earlier version is brought back to 0600 once held, which does not revoke a descriptor that another user already has open: reboot, `/run` being a tmpfs, or delete the file while no backup is running.
- **Batch purge in a single call.** Every archive to delete goes to one `tarsnap -d`, with `-f` repeated.
- **Purge circuit breaker.** A real run that would delete more than `MAX_PURGE` archives, 7 by default, deletes none of them and stops with an error, the archive of the run already created and `postbackup` already run. `--dry-run` prints the command and warns. `-F` or `--force-purge` lifts the limit for one run, never from the configuration block (N-R2-1, N-R1-6).
- **The archive of the current run is never purged.** Its name is compared with each archive of the list before anything else: whatever the clock says, a run cannot leave no archive at all (N-R1-12).
- **Strict naming pattern as the only purge scope.** Only names that exactly match `hostname-YYYY-MM-DD_HH-MM-SS` can be deleted: `.part` archives, snapshots taken with `-s` and every other name stay out of reach.
- **The body runs in `main()`, called by the last line.** The shell parses a function whole before running it, so the script can be edited or overwritten while a run is in progress. When the body ran as the shell read it, `dash` reading by blocks of 8 KiB and `bash` rereading after every external command, fragments of the new content ran as root (N-R2-7). The body is deliberately not indented, the configuration block and the functions stay outside `main()`, and the last line, `{ main "$@"; exit; }`, is read whole before `main()` starts.
- **`tarsnap-backup.sh` is never sourced** by the companion tools, only read: sourcing it would run its option parsing, take its lock and, in the end, make a real backup.
- **Shared functions stay identical.** `key_is_passphrased()`, `passphrase_reachable()`, `conf_keyfile()`, `check_dirs()` and `check_excludes()` exist in `tarsnap-backup.sh` and in `tarsnap-diff.sh`; `check_retention()`, `check_max_purge()` and `shown()` exist in `tarsnap-backup.sh` and in `rotation-check.sh`. Each pair keeps the same body, byte for byte, which the third command of [Validation](#validation) checks. `shown()` in `tarsnap-stats.sh` follows the same convention with a body of its own, its `sed` being found through `PATH`.
- **`decide()` follows the purge loop.** `rotation-check.sh` classifies and decides each archive as the purge loop of `tarsnap-backup.sh` does, condition for condition: same classification of the names, same date expressions, same order, same bounds, same sets of the weeks and months already represented, the archives taken in chronological order. The two cannot share a body, the loop acting where `decide()` only returns a verdict: a change to one goes to the other in the same commit, and replaying with `-l` the list given to a `--dry-run --verbose` must give the same verdicts.
- **Read-only modes take no lock.** `--orphans` and `tarsnap-diff.sh` only list or extract, which the Tarsnap manual allows in parallel with any other operation. `rotation-check.sh` does not run Tarsnap at all.
- **No code is removed for the sake of optimisation.** A line that looks redundant is often the trace of a bug that was fixed: removing it is a change of its own, with its own justification.

## Configuration read by the companion tools

`rotation-check.sh` and `tarsnap-diff.sh` read the configuration block of `tarsnap-backup.sh` with `sed`, by variable name:

| Variables | Read by | Expected form |
|---|---|---|
| `DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM`, `MAX_PURGE` | `rotation-check.sh` | `NAME=` followed by a decimal integer, unquoted, on a single line, which `check_retention()` and `check_max_purge()` then validate |
| `TARSNAP_KEY`, `TARSNAP_PASSPHRASE`, `BACKUP_DIRS`, `BACKUP_EXCLUDE` | `tarsnap-diff.sh` | `NAME="..."`, possibly empty, no double quote inside |

Hence:

- Renaming one of these variables breaks the tool that reads it.
- Both tools refuse a variable assigned on more than one line: the shell keeps the last assignment, and a tool reading the first one would read another value than the backup. `rotation-check.sh` also refuses a quoted value.
- The value is taken literally: no `$VARIABLE` expansion, and no quoting other than the one above.
- A string value stops at the first double quote after the opening one: a trailing comment may contain double quotes, the value itself cannot.
- A missing variable stops the tool that reads it: `tarsnap-diff.sh` therefore needs a `tarsnap-backup.sh` that already has `TARSNAP_PASSPHRASE`, and stops with `variable TARSNAP_PASSPHRASE not found` otherwise; `rotation-check.sh` needs `MAX_PURGE` likewise, and stops with `value MAX_PURGE not found`.

Both tools look for `/usr/local/sbin/tarsnap-backup.sh` first, then for a `tarsnap-backup.sh` in their own directory, unless `-f` names another one. Both stop when the installed file exists but cannot be read, rather than falling back silently on the copy of the repository (N-R1-21).

## Validation

Every change to a script goes through the following, run from the root of the repository:

```sh
for f in *.sh; do
    sh -n "$f" && dash -n "$f" && bash -n "$f" &&
        posh -n "$f" && busybox sh -n "$f" || echo "FAILED: $f"
done
shellcheck -s sh *.sh tests/*.sh tests/cases/*.sh tests/slow/*.sh tests/stub/*
for t in key_is_passphrased:tarsnap-backup.sh:tarsnap-diff.sh \
         passphrase_reachable:tarsnap-backup.sh:tarsnap-diff.sh \
         conf_keyfile:tarsnap-backup.sh:tarsnap-diff.sh \
         check_dirs:tarsnap-backup.sh:tarsnap-diff.sh \
         check_excludes:tarsnap-backup.sh:tarsnap-diff.sh \
         check_retention:tarsnap-backup.sh:rotation-check.sh \
         check_max_purge:tarsnap-backup.sh:rotation-check.sh \
         shown:tarsnap-backup.sh:rotation-check.sh; do
    fn=${t%%:*}; files=${t#*:}; a=${files%%:*}; b=${files#*:}
    x=$(sed -n "/^$fn() {/,/^}/p" "$a")
    y=$(sed -n "/^$fn() {/,/^}/p" "$b")
    [ -n "$x" ] && [ "$x" = "$y" ] || echo "DIFFERENT OR MISSING: $fn in $a and $b"
done
tests/run.sh
```

All four print nothing when everything is in order. The second runs ShellCheck on the four scripts and on the files of `tests/`. The third one compares, pair by pair, the bodies of the shared functions listed under [Invariants](#invariants): each triplet names the function, then the two scripts that hold it. The fourth runs the regression suite, in the foreground and for a few minutes, see [Regression tests](#regression-tests). Each mode touched by the change is then run for real, under `dash` and under `bash`, and the documentation is updated in the same commit.

On Debian, `apt install posh busybox shellcheck faketime locales` provides the tools that are not installed by default; `dpkg-reconfigure locales` then generates `en_US.UTF-8`, which the tests need, as the scripts do.

ShellCheck 0.9.0 (Debian Bookworm), 0.10.0 (Debian Trixie) and 0.11.0 (trixie-backports, Forky) report nothing, on the scripts as on `tests/`.

`posh -n` accepts the four scripts, but `posh` does not run `tarsnap-backup.sh` nor `tarsnap-diff.sh`: under `set -u`, it treats `"$@"` without positional parameters as an unset variable, which POSIX has exempted since 2008, and it does not recognise `[[:space:]]` in a `case` pattern. Both scripts stop with `@: parameter not set` from `-h` on (N-GAP2-8). `posh` is therefore not supported: the syntax check only guards against constructs foreign to POSIX, and the scripts run under `dash`, `bash` and `busybox sh`.

### Regression tests

`tests/` keeps the cases found by the audits fixed. Nothing runs in place: each case works in a directory of its own, created by `mktemp` and removed at the end, on copies of the scripts whose paths point into it, with a fake `tarsnap`. Neither the network, nor a Tarsnap account, nor root is needed.

| Path | Role |
|---|---|
| `tests/run.sh` | runs every case under `dash`, `bash` and `busybox sh`; prints nothing and exits with status 0 when all of them pass, prints what the failing ones reported and exits with status 1 otherwise. A case that passes but writes something counts as failed |
| `tests/lib.sh` | the helpers that every case sources. `t_init` creates the private directory, removed on every way out, and the scripts are copied there by `sed`, their paths rewritten: binaries replaced by the stubs, key, `BACKUP_DIRS`, lock, inventories, log directory, the installed copy of `tarsnap-backup.sh` and `/dev/tty`. A copy that still names a path outside that directory is refused before it runs. The clock is libfaketime, preloaded as the `faketime` command does it, the instant read from a file that a case can move during a run, in the `Europe/Paris` time zone |
| `tests/stub/` | a fake `tarsnap`, which keeps the archives of the account, the listings and the stored files of each archive in a state directory, and logs its calls; fakes of `apt`, `apt-mark`, `dpkg`, `logger` and `uname`. The fake `logger` never writes to the system log |
| `tests/fixtures/www-archives.txt` | the list of the archives of the author's machine, as `tarsnap --list-archives` printed it on 25 October 2026 |
| `tests/cases/` | one case per finding, named after its identifier: 73 of the 82 findings of the security audit, RC-03, TB-10, TD-09 and TS-04 of the initial one, and `shared.sh`, which checks the shared functions and reports any other function defined under the same name in two scripts, unless it is known to differ. 78 cases, two to three minutes for the three shells |
| `tests/slow/` | `agreement.sh` checks `rotation-check.sh -l` against a `--dry-run --verbose` of the backup, on five years of archives with missed nights and names at the edges, at several instants, the day without midnight of Havana included; `projection.sh` checks the projection against the backup replayed night after night, on the fixture and in a simulation. Several minutes per shell |

The options of `tests/run.sh`:

| Option | Effect |
|---|---|
| `-s` | also runs the slow checks of `tests/slow` |
| `-p` | also runs the checks that need a terminal, through `script`: the progress line of `tarsnap-stats.sh` and `tarsnap-diff.sh`, timing-dependent |
| `-r` | also runs the checks that need root: a device node, a mount namespace |
| `-t TARSNAP` | also runs the checks against a real `tarsnap`, built as below: `tarsnap -c --dry-run`, without a key, a cache directory or any configuration file |
| `-S SHELL` | one shell only: `dash`, `bash` or `busybox` |
| `-k` | keeps the directory of a failed case, and prints its path |
| `CASE...` | only these cases, by name: `TB-01`, `shared`, `agreement`... |

Run it in the foreground: a background job starts with SIGINT and SIGQUIT ignored, `nohup` ignores SIGHUP, and a shell cannot trap again a signal that was ignored when it started, so the cases about signals would fail. It needs `dash`, `bash`, `busybox`, `faketime` and the `en_US.UTF-8` locale, and `-p` needs `script` as well.

`tests/.shellcheckrc` disables SC2119 for the files of `tests/` only: the cases call the helpers of `lib.sh`, `run_backup` and the like, without arguments on purpose, where SC2119 would have them pass `"$@"` along. It is the only directive kept outside the code, and its scope stops at `tests/`: ShellCheck reads it for the files below that directory, never for the four scripts.

### Building Tarsnap 1.0.41 for the tests

A real client allows `--dry-run` runs without an account, since `tarsnap -c --dry-run` needs no key file. The dependencies on Debian Trixie, after the `BUILDING` file of the tag:

```sh
apt install gcc libc6-dev make libssl-dev zlib1g-dev libext2fs-dev autoconf automake autoconf-archive
```

`BUILDING` names `e2fslibs-dev`, which Trixie resolves to `libext2fs-dev`, a package that provides it. `autoconf`, `automake` and `autoconf-archive` are only needed to build from the git tag, through `autoreconf -i`, `./configure` and `make`; `BUILDING` keeps that route for development and recommends the signed tarballs otherwise. Built from the tag, the binary announces itself as `1.0.40-head`, the content of the `tar-version` file of that tag: it is nonetheless built from 1.0.41, commit `066c5ec`.

## ShellCheck directives

Each directive sits right above the command it covers, with its reason in a comment. In the four scripts, there are twenty-one of them, for five codes.

| Code | Where | Why |
|---|---|---|
| SC2086 | `tarsnap-backup.sh`: archive listing in `list_orphans()` and in the rotation, creation, purge. `tarsnap-diff.sh`: archive listing and extraction, two branches each, and the splitting of a listing line into its fields | `$TARSNAP_KEYOPT`, which carries `--keyfile` and `--passphrase`, and `$TARSNAP_MSGOPT` must vanish from the command line when they are empty, `$BACKUP_DIRS` is a list, and a line of the listing is split into its eight fields on purpose, `--numeric-owner` leaving no blank in the owner and group. `set -f` rules out globbing. As a consequence, neither the key path, nor the passphrase method, nor the entries of `BACKUP_DIRS` may contain whitespace: both scripts refuse a blank in `TARSNAP_KEY` and `TARSNAP_PASSPHRASE` before their first Tarsnap call. |
| SC1003 | `key_is_passphrased()`, in both scripts | The backslash belongs to the `i\` command of `sed`: it escapes nothing in the shell. |
| SC2317, SC2329 | `cleanup()`, in `rotation-check.sh` and in `tarsnap-diff.sh`; `log_exit()`, in `tarsnap-backup.sh` | The function is only called from the traps, which ShellCheck does not follow: it believes the body unreachable (SC2317) or, from ShellCheck 0.11.0 on, the function never invoked (SC2329). A single directive covers both codes. |
| SC2317 | `tarsnap-backup.sh`, last line | `main()` always exits, so ShellCheck reports the `exit` of `{ main "$@"; exit; }` as unreachable. It stays on purpose, so that the shell never reads beyond that line even if `main()` were to return, and the braces let the directive cover the whole line (N-R2-7). |
| SC2254 | `tarsnap-backup.sh`: `list_orphans()`, rotation loop, `is_safe_name()`. `rotation-check.sh`: replay loop. `tarsnap-diff.sh`: `is_excluded()`, two branches | An unquoted expansion used as a pattern, which has to be interpreted rather than matched literally: `$STAMP_GLOB`, the strict stamp of the archive names, in the three loops that classify the names; the explicit character list of `is_safe_name()`; the exclusion glob itself in `is_excluded()`. |

The files of `tests/` follow the same rule, with sixteen directives of their own, for six codes: SC2012, SC2016, SC2046, SC2086, SC2317 and SC2329. `tests/.shellcheckrc` is described under [Regression tests](#regression-tests).

## Technical choices

**`prebackup` and `postbackup` are called bare, through `run_hook()`.** Neither `run_hook prebackup || die` nor `if ! run_hook prebackup`: placing a function in a condition disables `set -e` throughout its body, so a command failing in the middle would be ignored, the following ones would still run, and the function would return 0. This behaviour has been verified to be identical under `dash` and under `bash`. Called bare, the hook stops the script on the failing command, whose own message goes to the `cron` mail.

`run_hook()` runs the hook in a subshell, so that the user's code does not inherit the internals of the script: descriptor 9, which a daemon started by a hook would keep open, every following run then finding the lock taken; the variable named by an `env:` passphrase, which every program started by a hook would receive (N-R5-1); and `-f`, under which `rm -f /root/dumps/*.sql` would remove nothing (N-R4-1). `set -e` remains active in the subshell. `postbackup` runs whatever the outcome of `tarsnap -c`, with its exit status as `$1`: 2, an archive created with unreadable files, gives a warning and a run that exits with 2, and any other failure stops the script before the rotation (TB-02).

Within a hook, `set -e` only stops the script on a command that fails on a line of its own: not in a pipeline, except in its last command, the script not setting `pipefail`, nor on the left of `&&` or `||`, nor in the condition of an `if` or a `while`. One command per line, and test what has to be tested (N-R2-11).

**`--quiet --no-print-stats --no-totals --no-progress-bytes`.** Without `--verbose`, the script passes these four options to Tarsnap. `--quiet` silences a few warnings such as "Removing leading '/'", among them "Archive contains no files" (`tar/write.c:464-466`), hence the refusal by `check_excludes()` of a pattern that would match everything. The three others override the `print-stats`, `totals` and `progress-bytes` directives of `tarsnap.conf`, which would otherwise write the statistics block, the total of bytes written or progress lines to standard error, hence a `cron` mail every night (N-GAP2-1). `--no-progress-bytes` requires Tarsnap 1.0.40 or later. The script only speaks up on errors.

**`printf`, not `echo`.** The behaviour of `echo` on a backslash or on an argument starting with `-` is not specified by POSIX: `dash` interprets escape sequences where `bash` does not. `printf` raises no such issue.

**Long options translated by hand.** POSIX `getopts` only knows single-character options. The long forms, with one or two leading dashes, are rewritten into short ones before `getopts` runs. `tarsnap-diff.sh` maps `--debug` to `-X`, a letter deliberately left out of the documented short options. Every script refuses the operands it does not expect: `getopts` stops at the first operand, so a mistyped option, `dry-run` without its dashes or behind a dash pasted from a document, would otherwise be ignored, and a dry-run asked for would become a real run (N-R1-2).

**Absolute binary paths, checked at startup.** They do not depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`, and a missing binary stops the script before anything else happens. The only exception is `usage()`, which calls `cat` by name: it can be reached through `-h` before the check, and must still display the help. `tarsnap-stats.sh` departs from the rule as a whole: like the version in its own repository, it finds its binaries through `PATH`, and `tarsnap` through the `TARSNAP` variable when it is set. The check covers thirteen binaries in `tarsnap-backup.sh`, seven in `rotation-check.sh` and fifteen in `tarsnap-diff.sh`, whose `stdbuf`, optional, is only looked for.

**`en_US.UTF-8` locale forced.** Tarsnap, `apt` and `date` then produce predictable output. `LANGUAGE` is unset, since GNU gettext would otherwise override `LC_MESSAGES`. `C.UTF-8`, which every Debian provides, is not used instead: the escapes that `tarsnap-diff.sh` undoes in the names of the listing were checked under `en_US.UTF-8` (TB-09, TD-05).

**Explicit character lists, never ranges.** The content of a range such as `[0-9]` or `[A-Za-z]` depends on the locale, and under `bash`, `[0-9]` also matches digits other than 0 to 9 (N-R2-9). The strict stamp of the archive names, `STAMP_GLOB`, therefore spells out `[0123456789]`, and `is_safe_name()` and the check of an `env:` variable name give their letters in full. `shown()` keeps a range, `[^ -~]`, but under `LC_ALL=C`, where it is a range of bytes: every byte outside printable ASCII becomes `?`, so that an archive name holding ESC or CR can neither drive the terminal nor garble the `cron` mail (N-R2-4). The delete commands printed by `--orphans` only take the names that `is_safe_name()` accepts: the others stay listed above them, and are counted apart (TB-03).

**The archive list read line by line, its dates checked.** The output of `--list-archives` is read with `while IFS= read -r`, never split on blanks, so that a name holding a space stays one name (N-R1-11). The dates are computed from noon of the archive day, its midnight taken as noon minus 12 hours: in the time zones where the change to summer time skips midnight, `date -d "$day"` would fail and stop the purge (N-R1-13). A name of the strict form whose date does not exist, 30 February for instance, is kept with a warning instead of stopping the run (TB-04).

**Why a batch purge is faster.** A single `tarsnap -d` invocation opens one storage reader for all the deletions, with a block cache: what a deletion has already fetched can be served from that cache to the next ones instead of being downloaded again. See `tarsnap_mode_d()` in `tar/glue/tape.c` and `deletetape()` in `tar/multitape/multitape_delete.c`. Tarsnap 1.0.33 already announced a significant speedup of multi-archive deletes.

**`tarsnap-diff.sh`: a single extraction.** The files to compare byte by byte are gathered first, then extracted in one Tarsnap invocation through `-T`, which reads the list of names from a file. One invocation per file would reopen the archive on the server side every time, which becomes ruinous from a hundred files onwards. `tarsnap -x` reads each line of `-T` as a pattern, glob characters and backslash included: the names are escaped first (N-R1-9, TD-15), and the target of every hard link among them is added, Tarsnap only recreating a link next to its target (TD-04). Only regular files are then compared, `cmp` following symbolic links (TD-03), and a failed extraction, whose copies may be partial, has none compared (N-R2-14).

**`tarsnap-diff.sh`: dates compared as strings, in UTC.** `tarsnap -tv --iso-dates` and `find -printf '%TY-%Tm-%Td %TH:%TM:%TS'` both give the time as `YYYY-MM-DD HH:MM:SS`, once the fractional seconds printed by `find` are truncated, and both run with `TZ=UTC0`. Comparing the strings avoids forking one `date` per entry: over the 50,000 entries of a real machine, that took several minutes of pure forking. It gives the same verdict as comparing epochs, which local time did not in the hour repeated when the clocks go back: t and t + 3600 s printed the same, and a file of the same size rewritten exactly one hour later came out as `=`, without being downloaded (N-R2-13). A rewrite of the same size within the same second stays invisible in any case, both sides counting in seconds (N-R2-12).

**`tarsnap-diff.sh`: `LC_ALL=C` on `sort` and `join`.** `join` silently misbehaves when the collation order of its inputs is not its own. `sort -u` on the key also guards against a path present twice, which would otherwise produce the Cartesian product of the duplicates.

**`tarsnap-diff.sh`: the header of the log.** It carries the counters, so it can only be written last. The detail lines go to a first working file, created by `mktemp` next to the log and opened once, for appending on descriptor 3 and for reading on descriptor 4, never reopened by its path (N-R1-16). At the end, the header is written into a second working file, followed by the details read back through descriptor 4, and that file is renamed over the log: the rename stays within the same file system, hence it is atomic. Until then nothing touches the log, so a run that fails or is interrupted leaves the previous log as it was (TD-11).

**`tarsnap-diff.sh`: working files created by `mktemp`.** The log is never opened in place. With `-l` pointing into a directory that everyone can write to, `/tmp` for instance, a symbolic link planted beforehand under the name of the log would be followed by an opening in place, whereas `rename()` replaces it. Both working files get random names, created with `O_EXCL`: a predictable name could be planted beforehand, as a link or as a file owned by someone else. Both are in mode 0600, so the log keeps that mode from start to finish. Under the name of the log itself, only a regular file, or nothing yet, is accepted: the rename would replace a device such as `/dev/null`, or a symbolic link, with a regular file (N-R3-2). The directory of the log is made canonical first, so that the check against `BACKUP_DIRS` sees through a relative path, a `//` or a link (TD-08).

**`tarsnap-diff.sh`: the walk covers what `tarsnap -c` archives.** The cache directory of Tarsnap stays out, as `tarsnap -c` leaves it out (`tar/write.c:958-968`), and so do the temporary directory and the working file of the details (N-GAP2-3). Unless `tarsnap.conf` has `insane-filesystems`, the mount point of a synthetic file system crossed during the walk is listed but not entered, as `tar/write.c:871-896` does, for the Linux types of `synthetic_filesystems[]` in `lib-platform/util/ts_getfstype.c`; the file system of a starting point is accepted from the outset, `tar/write.c:863` recording its device first (N-GAP2-2). `find` runs with `-ignore_readdir_race`, and its errors give a warning instead of stopping the diff (N-R2-8). The `nodump` directive of `tarsnap.conf` is not reproduced: a file flagged `nodump` comes out as new.

**`tarsnap-diff.sh`: the configuration of Tarsnap read, not applied.** Both Tarsnap calls get `--no-config-exclude` and `--no-config-include`, since Tarsnap would otherwise apply the exclusions of `tarsnap.conf` to the listing and to the extraction, silently and on one side only. `conf_excludes()` reads them from `--dump-config`, every `exclude` line of every file read, Tarsnap adding them all up, and `is_excluded()` applies them on both sides, next to `BACKUP_EXCLUDE`; an `include` directive is reported, not reproduced (N-R1-19). The cache directory and `insane-filesystems` come from the same output.

**`tarsnap-diff.sh`: the names as Tarsnap prints them.** `unescape()` undoes, through `printf %b`, the escapes of `bsdtar_expand_char()` in `tar/util.c`: a doubled backslash, `\a`, `\b`, `\f`, `\n`, `\r`, `\t` and `\v` for those control characters, and three octal digits for any other byte that is not printable, such as a byte of an invalid UTF-8 sequence (TD-05). A name holding a newline or a tab is counted apart, on both sides, the inventories being lines of tab-separated fields (N-R1-1). `in_dirs()` keeps the entries outside the current `BACKUP_DIRS` out of the deleted ones (N-R3-1), `ctl_safe()` writes the control bytes of a name as `?` in the log and in the warnings (N-R3-4), and of a path stored twice in the archive, the last occurrence is kept, the one that `tarsnap -x` restores (N-R2-15).

**`tarsnap-backup.sh`: the cache state looked for in a dry run.** Tarsnap refuses to delete without the `directory` file of its cache directory (`tar/bsdtar.c:1001-1012`, through `chunks_directory_exists()`), which a reinstall, a rollback or a cache directory restored from elsewhere can lose or leave out of date, and a simulated creation reads no state: a dry run would pass where every real run fails. `conf_cachedir()` therefore reads the `cachedir` of `--dump-config`, as `conf_keyfile()` reads the key, and a dry run warns when that file is missing while the account holds archives (N-GAP1-4). It is not a shared function: `tarsnap-diff.sh` reads the cache directory together with `insane-filesystems`.

**`tarsnap-backup.sh`: a real run ends in the system log.** An EXIT trap, set once the options are read and only for a real run, hands `logger` the exit status, never the text of `die` (N-R1-14), and rewrites `LAST_SUCCESS` after a run that created its archive, status 0 or 2 (N-GAP1-6). HUP, INT and TERM end the run with 129, 130 and 143, so that the trap records them; they run no hook. A subshell does not inherit the trap: a failed hook is logged once, by the main shell. The tests replace `logger` with `tests/stub/logger`, and never write to the system log.

## Passphrase and key detection

Three functions exist in `tarsnap-backup.sh` and in `tarsnap-diff.sh`, and must keep the same body, byte for byte: the third command of [Validation](#validation) checks it. Only the comments above them are adapted to each script.

**`key_is_passphrased()`** follows `lib/keyfile/keyfile.c` of Tarsnap: once comments and blank lines are skipped, the base64 of an encrypted key starts with `c2NyeXB0`, the encoding of `scrypt`, so no decoding is needed. `sed` returns a fixed verdict rather than the line, so the NUL bytes of a raw binary key never reach the shell. Known limitation: a key file whose lines end with a lone CR is seen as a single comment line, hence reported as not protected; `tarsnap-keygen` and `tarsnap-keymgmt` write LF, and CRLF is handled.

**`passphrase_reachable()`** tells whether Tarsnap can obtain the passphrase of a protected key with the method of `TARSNAP_PASSPHRASE`, mirroring Tarsnap 1.0.41 method by method:

| Method | Tarsnap reads | Checked here |
|---|---|---|
| empty, `dev:tty-stdin` | `/dev/tty`, then standard input, through `readpass()` | `/dev/tty` opens, or standard input is a terminal |
| `dev:tty-once` | `/dev/tty` only | `/dev/tty` opens |
| `dev:stdin-once` | standard input only | standard input is a terminal |
| `env:NAME` | the variable, through `getenv()` | the variable is set and not empty, tested through `${NAME:+x}`: the value enters neither a shell variable nor the `set -x` trace of `--debug` |
| `file:PATH` | a single line of at most 2047 bytes, LF included, ending at its first CR, LF or NUL, through `readpass_file()` | the file is readable, is not a directory, and holds a single line of at most 2047 bytes, neither empty nor starting with a CR or a NUL; `sed` reads bytes (`LC_ALL=C`) and only answers the verdict, so the passphrase never reaches the shell |

`/dev/tty` is really opened, rather than tested with `[ -r ]`. An empty variable or file is refused as well: Tarsnap would read an empty passphrase and fail on it, later (TB-11, TD-01). The messages about an invalid `TARSNAP_PASSPHRASE` never print its value (N-R1-14). A file that is not a regular one, a FIFO or a device, is only checked for readability, so as not to consume it. The function sets `PASSPHRASE_HOW` for the verbose message and `PASSPHRASE_WHY` for the error message. Its `eval` only ever sees a variable name validated beforehand, against an explicit list of characters rather than a range such as `[A-Za-z]`, whose content depends on the locale.

**`conf_keyfile()`** asks Tarsnap which key `tarsnap.conf` designates, when `TARSNAP_KEY` is empty. `--dump-config` alone switches Tarsnap to its `--verify-config` mode, which exits before loading the key (`tar/bsdtar.c`, 1.0.41): no passphrase prompt and no network access. The function relies on this output:

- everything on standard error, nothing on standard output, exit status 0;
- the command line first, then a `Reading from config file:` header for each file tried, even a missing one, in reading order, `--configfile` first;
- after each header, the option lines of that file, leading blanks stripped, indented by two spaces;
- the first value wins, hence the first `  keyfile` line after the first header.

The key stays unknown when this answer is not reliable: a non-zero exit (Tarsnap older than 1.0.40, invalid configuration), no `keyfile` line, an argument starting with `~`, which Tarsnap expands from the password database and not from `$HOME`, or an argument containing a blank, which Tarsnap keeps with a warning. Both scripts then only check an `env:` or `file:` method.

## Exclusion matching in Tarsnap

`tarsnap -c` matches the exclusion patterns against the path of each entry as found on disk, leading `/` included: `write_hierarchy()` takes the `tree_current_path()` of the entry (`tar/write.c:779`) and tests it with `excluded()` (`tar/write.c:808`), before `edit_pathname()` strips that `/` from the name stored in the archive (`tar/write.c:988`).

`match_exclusion()` (`tar/matching.c:204-213`) then applies two rules:

- a pattern starting with `/` or `*` is matched against the whole path, hence anchored at the root when it starts with `/`;
- any other pattern is tried after each `/` of the path, hence at every component.

The comparison goes through `pathmatch()` (`tar/matching.c:308-327`), which strips a leading `./` from the pattern and from the path, then through `fnmatch()` with `FNM_LEADING_DIR` (`tar/matching.c:337`), so that a pattern matching a directory also matches everything below it. That branch is the one taken with glibc, `configure` checking the flag with `_GNU_SOURCE` defined (`configure.ac:357-364`); without it, a built-in copy of `fnmatch()` always behaves as if `FNM_LEADING_DIR` were set.

Consequences for the scripts:

- `tarsnap-backup.sh` passes an absolute pattern as is, hence anchored at the root, and adds `pattern/*` for its contents, which only repeats what `FNM_LEADING_DIR` already does and stays as a safety. Without its leading `/`, the pattern would be tried at every level, and would also exclude every directory of the same name further down (TB-07).
- `check_excludes()`, shared by `tarsnap-backup.sh` and `tarsnap-diff.sh`, removes the trailing slashes, which `tarsnap-diff.sh` would otherwise compare as written, and refuses `/` alone, which would exclude every entry of `BACKUP_DIRS` without a message (N-R2-5).
- `is_excluded()` in `tarsnap-diff.sh` reproduces `match_exclusion()` on `/` followed by the stored path: a pattern starting with `/` or `*` is matched from the root, any other after some `/`, each one on the path itself and on everything below it (TD-02).

These line numbers refer to the `1.0.41` tag of the Tarsnap repository.

## The `--dry-run-metadata` bug

`tarsnap-backup.sh --dry-run` simulates the creation with Tarsnap's `--dry-run`, which rereads all the files and therefore takes as long as a real backup. `--dry-run-metadata`, added in Tarsnap 1.0.41, would be much faster, since it reads no data, but it fails as soon as the chunk cache is populated:

```text
tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
tarsnap: Error writing cached archive entry
```

Reproduced in 1.0.41 on each of the four directories of `BACKUP_DIRS` taken individually, with a `cachedir` coming from a real backup. The same call against a freshly initialised `cachedir` goes through without a hitch, which isolates the cache as the only variable. Nor is it a matter of volume: `/boot` alone is enough.

`print-stats` has nothing to do with it either: the failure also occurs with `--no-print-stats`. Note, however, that a single file passed as an argument is not always enough to trigger the error, even if it is in the cache: the cache has to be able to provide a complete archive entry.

The cause can be seen in the 1.0.41 source. `multitape_write.c:429` sets `no_chunkifiers = (dryrun == 2)`, which deprives the streams initialised on lines 517 to 521 of a chunkifier, whereas the chunk layer `d->C` is created on line 503 with no condition on `dryrun`. As a result, `writetape_ischunkpresent` answers "present" where `writetape_writechunk` returns 0, and `ccache_entry.c:407-409` treats that 0 as a programmer error. These line numbers refer to the `1.0.41` tag of the Tarsnap repository.

Do not put the option back without checking that this has been fixed upstream. The command that reproduces it, read-only and on a copy of the cache:

```sh
cp -a /usr/local/tarsnap-cache /root/ts-cache-test
tarsnap --cachedir /root/ts-cache-test --dry-run-metadata --no-print-stats -c -f zz-test /boot
echo $?
```
