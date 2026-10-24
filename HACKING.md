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
- **Shared functions stay identical.** `key_is_passphrased()`, `passphrase_reachable()`, `conf_keyfile()`, `check_dirs()` and `check_excludes()` exist in `tarsnap-backup.sh` and in `tarsnap-diff.sh`; `check_retention()` and `shown()` exist in `tarsnap-backup.sh` and in `rotation-check.sh`. Each pair keeps the same body, byte for byte, which the third command of [Validation](#validation) checks. `shown()` in `tarsnap-stats.sh` follows the same convention with a body of its own, its `sed` being found through `PATH`.
- **`decide()` follows the purge loop.** `rotation-check.sh` classifies and decides each archive as the purge loop of `tarsnap-backup.sh` does, condition for condition: same classification of the names, same date expressions, same order, same bounds, same sets of the weeks and months already represented, the archives taken in chronological order. The two cannot share a body, the loop acting where `decide()` only returns a verdict: a change to one goes to the other in the same commit, and replaying with `-l` the list given to a `--dry-run --verbose` must give the same verdicts.
- **Read-only modes take no lock.** `--orphans` and `tarsnap-diff.sh` only list or extract, which the Tarsnap manual allows in parallel with any other operation. `rotation-check.sh` does not run Tarsnap at all.
- **No code is removed for the sake of optimisation.** A line that looks redundant is often the trace of a bug that was fixed: removing it is a change of its own, with its own justification.

## Configuration read by the companion tools

`rotation-check.sh` and `tarsnap-diff.sh` read the configuration block of `tarsnap-backup.sh` with `sed`, by variable name:

| Variables | Read by | Expected form |
|---|---|---|
| `DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM` | `rotation-check.sh` | `NAME=` followed by a decimal integer, unquoted, on a single line, which `check_retention()` then validates |
| `TARSNAP_KEY`, `TARSNAP_PASSPHRASE`, `BACKUP_DIRS`, `BACKUP_EXCLUDE` | `tarsnap-diff.sh` | `NAME="..."`, possibly empty, no double quote inside |

Hence:

- Renaming one of these variables breaks the tool that reads it.
- `tarsnap-diff.sh` only reads the first line starting with `NAME=`, whereas the shell keeps the last assignment: a second definition further down would make the tool and the backup disagree. `rotation-check.sh` refuses a variable assigned on more than one line, and a quoted value.
- The value is taken literally: no `$VARIABLE` expansion, and no quoting other than the one above.
- A string value stops at the first double quote after the opening one: a trailing comment may contain double quotes, the value itself cannot.
- A missing variable stops the tool that reads it: `tarsnap-diff.sh` therefore needs a `tarsnap-backup.sh` that already has `TARSNAP_PASSPHRASE`, and stops with `variable TARSNAP_PASSPHRASE not found` otherwise.

Both tools look for `/usr/local/sbin/tarsnap-backup.sh` first, then for a `tarsnap-backup.sh` in their own directory, unless `-f` names another one. `rotation-check.sh` stops when the installed file exists but cannot be read, rather than falling back silently on the copy of the repository (N-R1-21); `tarsnap-diff.sh` does not do so yet.

## Validation

Every change to a script goes through the following, run from the root of the repository:

```sh
for f in *.sh; do
    sh -n "$f" && dash -n "$f" && bash -n "$f" &&
        posh -n "$f" && busybox sh -n "$f" || echo "FAILED: $f"
done
shellcheck -s sh *.sh
for t in key_is_passphrased:tarsnap-backup.sh:tarsnap-diff.sh \
         passphrase_reachable:tarsnap-backup.sh:tarsnap-diff.sh \
         conf_keyfile:tarsnap-backup.sh:tarsnap-diff.sh \
         check_dirs:tarsnap-backup.sh:tarsnap-diff.sh \
         check_excludes:tarsnap-backup.sh:tarsnap-diff.sh \
         check_retention:tarsnap-backup.sh:rotation-check.sh \
         shown:tarsnap-backup.sh:rotation-check.sh; do
    fn=${t%%:*}; files=${t#*:}; a=${files%%:*}; b=${files#*:}
    x=$(sed -n "/^$fn() {/,/^}/p" "$a")
    y=$(sed -n "/^$fn() {/,/^}/p" "$b")
    [ -n "$x" ] && [ "$x" = "$y" ] || echo "DIFFERENT OR MISSING: $fn in $a and $b"
done
```

All three print nothing when everything is in order. The third one compares, pair by pair, the bodies of the shared functions listed under [Invariants](#invariants): each triplet names the function, then the two scripts that hold it. Each mode touched by the change is then run for real, under `dash` and under `bash`, and the documentation is updated in the same commit.

On Debian, `apt install posh busybox shellcheck` provides the tools that are not installed by default.

ShellCheck 0.9.0 (Debian Bookworm), 0.10.0 (Debian Trixie) and 0.11.0 (trixie-backports, Forky) report nothing.

`posh -n` accepts the four scripts, but `posh` does not run `tarsnap-backup.sh` nor `tarsnap-diff.sh`: under `set -u`, it treats `"$@"` without positional parameters as an unset variable, which POSIX has exempted since 2008, and it does not recognise `[[:space:]]` in a `case` pattern. Both scripts stop with `@: parameter not set` from `-h` on (N-GAP2-8). `posh` is therefore not supported: the syntax check only guards against constructs foreign to POSIX, and the scripts run under `dash`, `bash` and `busybox sh`.

### Regression tests, planned

A `tests/` directory is planned, so that the cases found by the audit stay fixed. Proposed layout:

- `tests/stub/tarsnap`: a fake `tarsnap` that logs its arguments, accepts `-c` and `-d`, and serves `--list-archives`, `-tv`, `-x`, `--dump-config` and `--print-stats` from fixture files, so that every mode runs without an account;
- `tests/lib.sh`: helpers that copy a script with its paths rewritten by `sed` (binaries, key, lock, inventories, log directory), run it, and compare its output and its exit status with the expected ones;
- `tests/cases/<ID>.sh`: one case per audit finding, named after its identifier, such as `TB-01.sh` or `N-R1-12.sh`, plus the agreement of `rotation-check.sh -l` with a `--dry-run --verbose` of the backup on the same list of archives;
- `tests/run.sh`: runs every case under `dash`, `bash` and `busybox sh`, prints nothing when all of them pass and exits with a non-zero status otherwise, so that it can join the validation above.

### Building Tarsnap 1.0.41 for the tests

A real client allows `--dry-run` runs without an account, since `tarsnap -c --dry-run` needs no key file. The dependencies on Debian Trixie, after the `BUILDING` file of the tag:

```sh
apt install gcc libc6-dev make libssl-dev zlib1g-dev libext2fs-dev autoconf automake autoconf-archive
```

`BUILDING` names `e2fslibs-dev`, which Trixie resolves to `libext2fs-dev`, a package that provides it. `autoconf`, `automake` and `autoconf-archive` are only needed to build from the git tag, through `autoreconf -i`, `./configure` and `make`; `BUILDING` keeps that route for development and recommends the signed tarballs otherwise. Built from the tag, the binary announces itself as `1.0.40-head`, the content of the `tar-version` file of that tag: it is nonetheless built from 1.0.41, commit `066c5ec`.

## ShellCheck directives

Each directive sits right above the command it covers, with its reason in a comment. There are nineteen of them, for five codes.

| Code | Where | Why |
|---|---|---|
| SC2086 | `tarsnap-backup.sh`: archive listing in `list_orphans()` and in the rotation, creation, purge. `tarsnap-diff.sh`: archive listing and extraction, two branches each | `$TARSNAP_KEYOPT`, which carries `--keyfile` and `--passphrase`, and `$TARSNAP_MSGOPT` must vanish from the command line when they are empty, and `$BACKUP_DIRS` is a list. `set -f` rules out globbing. As a consequence, neither the key path, nor the passphrase method, nor the entries of `BACKUP_DIRS` may contain whitespace: both scripts refuse a blank in `TARSNAP_KEY` and `TARSNAP_PASSPHRASE` before their first Tarsnap call. |
| SC1003 | `key_is_passphrased()`, in both scripts | The backslash belongs to the `i\` command of `sed`: it escapes nothing in the shell. |
| SC2317, SC2329 | `cleanup()`, in `rotation-check.sh` and in `tarsnap-diff.sh` | The function is only called from the traps, which ShellCheck does not follow: it believes the body unreachable (SC2317) or, from ShellCheck 0.11.0 on, the function never invoked (SC2329). A single directive covers both codes. |
| SC2317 | `tarsnap-backup.sh`, last line | `main()` always exits, so ShellCheck reports the `exit` of `{ main "$@"; exit; }` as unreachable. It stays on purpose, so that the shell never reads beyond that line even if `main()` were to return, and the braces let the directive cover the whole line (N-R2-7). |
| SC2254 | `tarsnap-backup.sh`: `list_orphans()`, rotation loop, `is_safe_name()`. `rotation-check.sh`: replay loop. `tarsnap-diff.sh`: `is_excluded()`, two branches | An unquoted expansion used as a pattern, which has to be interpreted rather than matched literally: `$STAMP_GLOB`, the strict stamp of the archive names, in the three loops that classify the names; the explicit character list of `is_safe_name()`; the exclusion glob itself in `is_excluded()`. |

## Technical choices

**`prebackup` and `postbackup` are called bare, through `run_hook()`.** Neither `run_hook prebackup || die` nor `if ! run_hook prebackup`: placing a function in a condition disables `set -e` throughout its body, so a command failing in the middle would be ignored, the following ones would still run, and the function would return 0. This behaviour has been verified to be identical under `dash` and under `bash`. Called bare, the hook stops the script on the failing command, whose own message goes to the `cron` mail.

`run_hook()` runs the hook in a subshell, so that the user's code does not inherit the internals of the script: descriptor 9, which a daemon started by a hook would keep open, every following run then finding the lock taken; the variable named by an `env:` passphrase, which every program started by a hook would receive (N-R5-1); and `-f`, under which `rm -f /root/dumps/*.sql` would remove nothing (N-R4-1). `set -e` remains active in the subshell. `postbackup` runs whatever the outcome of `tarsnap -c`, with its exit status as `$1`: 2, an archive created with unreadable files, gives a warning and a run that exits with 2, and any other failure stops the script before the rotation (TB-02).

Within a hook, `set -e` only stops the script on a command that fails on a line of its own: not in a pipeline, except in its last command, `dash` having no `pipefail`, nor on the left of `&&` or `||`, nor in the condition of an `if` or a `while`. One command per line, and test what has to be tested (N-R2-11).

**`--quiet --no-print-stats --no-totals --no-progress-bytes`.** Without `--verbose`, the script passes these four options to Tarsnap. `--quiet` silences a few warnings such as "Removing leading '/'", among them "Archive contains no files" (`tar/write.c:464-466`), hence the refusal by `check_excludes()` of a pattern that would match everything. The three others override the `print-stats`, `totals` and `progress-bytes` directives of `tarsnap.conf`, which would otherwise write the statistics block, the total of bytes written or progress lines to standard error, hence a `cron` mail every night (N-GAP2-1). `--no-progress-bytes` requires Tarsnap 1.0.40 or later. The script only speaks up on errors.

**`printf`, not `echo`.** The behaviour of `echo` on a backslash or on an argument starting with `-` is not specified by POSIX: `dash` interprets escape sequences where `bash` does not. `printf` raises no such issue.

**Long options translated by hand.** POSIX `getopts` only knows single-character options. The long forms, with one or two leading dashes, are rewritten into short ones before `getopts` runs. `tarsnap-diff.sh` maps `--debug` to `-X`, a letter deliberately left out of the documented short options. Every script refuses the operands it does not expect: `getopts` stops at the first operand, so a mistyped option, `dry-run` without its dashes or behind a dash pasted from a document, would otherwise be ignored, and a dry-run asked for would become a real run (N-R1-2).

**Absolute binary paths, checked at startup.** They do not depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`, and a missing binary stops the script before anything else happens. The only exception is `usage()`, which calls `cat` by name: it can be reached through `-h` before the check, and must still display the help. `tarsnap-stats.sh` departs from the rule as a whole: like the version in its own repository, it finds its binaries through `PATH`, and `tarsnap` through the `TARSNAP` variable when it is set.

**`en_US.UTF-8` locale forced.** Tarsnap, `apt` and `date` then produce predictable output. `LANGUAGE` is unset, since GNU gettext would otherwise override `LC_MESSAGES`.

**Explicit character lists, never ranges.** The content of a range such as `[0-9]` or `[A-Za-z]` depends on the locale, and under `bash`, `[0-9]` also matches digits other than 0 to 9 (N-R2-9). The strict stamp of the archive names, `STAMP_GLOB`, therefore spells out `[0123456789]`, and `is_safe_name()` and the check of an `env:` variable name give their letters in full. `shown()` keeps a range, `[^ -~]`, but under `LC_ALL=C`, where it is a range of bytes: every byte outside printable ASCII becomes `?`, so that an archive name holding ESC or CR can neither drive the terminal nor garble the `cron` mail (N-R2-4). The delete commands printed by `--orphans` only take the names that `is_safe_name()` accepts: the others stay listed above them, and are counted apart (TB-03).

**The archive list read line by line, its dates checked.** The output of `--list-archives` is read with `while IFS= read -r`, never split on blanks, so that a name holding a space stays one name (N-R1-11). The dates are computed from noon of the archive day, its midnight taken as noon minus 12 hours: in the time zones where the change to summer time skips midnight, `date -d "$day"` would fail and stop the purge (N-R1-13). A name of the strict form whose date does not exist, 30 February for instance, is kept with a warning instead of stopping the run (TB-04).

**Why a batch purge is faster.** A single `tarsnap -d` invocation opens one storage reader for all the deletions, with a block cache: what a deletion has already fetched can be served from that cache to the next ones instead of being downloaded again. See `tarsnap_mode_d()` in `tar/glue/tape.c` and `deletetape()` in `tar/multitape/multitape_delete.c`. Tarsnap 1.0.33 already announced a significant speedup of multi-archive deletes.

**`tarsnap-diff.sh`: a single extraction.** The files to compare byte by byte are gathered first, then extracted in one Tarsnap invocation through `-T`, which reads the list of names from a file. One invocation per file would reopen the archive on the server side every time, which becomes ruinous from a hundred files onwards.

**`tarsnap-diff.sh`: dates compared as strings.** `tarsnap -tv --iso-dates` and `find -printf '%TY-%Tm-%Td %TH:%TM:%TS'` both give the local time as `YYYY-MM-DD HH:MM:SS`, once the fractional seconds printed by `find` are truncated. Comparing the strings avoids forking one `date` per entry: over the 50,000 entries of a real machine, that took several minutes of pure forking. It gives the same verdict as comparing epochs, except in the hour repeated when the clocks go back, where t and t + 3600 s print the same: a file of the same size rewritten exactly one hour later then comes out as `=`, without being downloaded (N-R2-13). Setting `TZ=UTC0` on both sources would remove the case, and is left to the series of `tarsnap-diff.sh`. A rewrite of the same size within the same second stays invisible in any case, both sides counting in seconds (N-R2-12).

**`tarsnap-diff.sh`: `LC_ALL=C` on `sort` and `join`.** `join` silently misbehaves when the collation order of its inputs is not its own. `sort -u` on the key also guards against a path present twice, which would otherwise produce the Cartesian product of the duplicates.

**`tarsnap-diff.sh`: the header of the log.** It carries the counters, so it can only be written last: it is built in a working file that `mktemp` creates next to the log, followed by the accumulated details, then renamed over the log. The rename stays within the same file system, hence it is atomic.

**`tarsnap-diff.sh`: log files created by `mktemp`.** The log is not opened in place: it is created by `mktemp` next to its final path, then renamed onto it. With `-l` pointing into a directory that everyone can write to, `/tmp` for instance, a symbolic link planted beforehand under the name of the log would be followed by an opening in place, whereas `rename()` replaces it. The working file of the header gets a random name for the same reason, created with `O_EXCL`: a predictable name could be planted beforehand, as a link or as a file owned by someone else. Both files are in mode 0600, so the log keeps that mode from start to finish.

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
| `file:PATH` | a single line, ending at its first CR or LF, through `readpass_file()` | the file is readable and holds a single line, neither empty nor starting with a CR; `sed` only answers the verdict, so the passphrase never reaches the shell |

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
