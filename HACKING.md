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
- [The `--dry-run-metadata` bug](#the---dry-run-metadata-bug)

## Repository layout

| File | Role |
|---|---|
| `tarsnap-backup.sh` | backup and rotation, carries the configuration |
| `rotation-check.sh` | replays the rotation logic, never runs Tarsnap |
| `tarsnap-diff.sh` | compares a snapshot with the system, read-only |
| `tarsnap-stats.sh` | sizes, deduplication and cost, copied from its own repository |

`tarsnap-stats.sh` is maintained in [deuza/tarsnap-stats](https://github.com/deuza/tarsnap-stats), which remains its source of truth: it is never modified here, only resynchronised from there, and a fix goes upstream first.

The scripts are written in strictly POSIX `sh` and run under `dash` as well as `bash`, but they target Debian on purpose: binaries under `/usr/bin` (`usrmerge`), GNU `date -d` and `%-d`, GNU `find -printf`, and GNU `sed` reading the binary content of a raw key file.

## Invariants

A change that breaks one of these is a regression, whatever it gains elsewhere.

- **Creation before deletion.** The new archive exists before the purge starts, and a failure anywhere before that point deletes nothing.
- **`set -euf`.** Exit on the first error, unset variables are fatal, and no pathname expansion at all: `-f` disables globbing everywhere, patterns written out in full included, not only on unquoted expansions. The hooks get it back, see [Technical choices](#technical-choices). `tarsnap-stats.sh` follows its own repository, with `set -eu`.
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
| `DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM` | `rotation-check.sh` | `NAME=` followed by digits, unquoted |
| `TARSNAP_KEY`, `TARSNAP_PASSPHRASE`, `BACKUP_DIRS`, `BACKUP_EXCLUDE` | `tarsnap-diff.sh` | `NAME="..."`, possibly empty, no double quote inside |

Hence:

- Renaming one of these variables breaks the tool that reads it.
- Only the first line starting with `NAME=` counts, whereas the shell keeps the last assignment: a second definition further down would make the tools and the backup disagree.
- The value is taken literally: no `$VARIABLE` expansion, and no quoting other than the one above.
- A string value stops at the first double quote after the opening one: a trailing comment may contain double quotes, the value itself cannot.
- A missing variable stops the tool that reads it: `tarsnap-diff.sh` therefore needs a `tarsnap-backup.sh` that already has `TARSNAP_PASSPHRASE`, and stops with `variable TARSNAP_PASSPHRASE not found` otherwise.

Both tools look for `/usr/local/sbin/tarsnap-backup.sh` first, then for a `tarsnap-backup.sh` in their own directory, unless `-f` names another one.

## Validation

Every change to a script goes through the following, run from the root of the repository:

```sh
for f in *.sh; do sh -n "$f" && dash -n "$f" && bash -n "$f" || echo "FAILED: $f"; done
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

ShellCheck 0.9.0 (Debian Bookworm), 0.10.0 (Debian Trixie) and 0.11.0 (trixie-backports, Forky) report nothing.

## ShellCheck directives

Each directive sits right above the command it covers, with its reason in a comment. There are thirteen of them, for six codes.

| Code | Where | Why |
|---|---|---|
| SC2086 | `tarsnap-backup.sh`: archive listing in `list_orphans()` and in the rotation, creation, purge. `tarsnap-diff.sh`: archive listing and extraction, two branches each | `$TARSNAP_KEYOPT`, which carries `--keyfile` and `--passphrase`, and `$TARSNAP_MSGOPT` must vanish from the command line when they are empty, and `$BACKUP_DIRS` is a list. `set -f` rules out globbing. As a consequence, neither the key path, nor the passphrase method, nor the entries of `BACKUP_DIRS` may contain whitespace: both scripts refuse a blank in `TARSNAP_KEY` and `TARSNAP_PASSPHRASE` before their first Tarsnap call. |
| SC1003 | `key_is_passphrased()`, in both scripts | The backslash belongs to the `i\` command of `sed`: it escapes nothing in the shell. |
| SC2046 | `rotation-check.sh`, replay mode | `set -- $(date ...)` is meant to split the three fields printed by `date`. |
| SC2317, SC2329 | `tarsnap-diff.sh`, `cleanup()` | The function is only called from the traps, which ShellCheck does not follow: it believes the body unreachable (SC2317) or, from ShellCheck 0.11.0 on, the function never invoked (SC2329). A single directive covers both codes. |
| SC2254 | `tarsnap-diff.sh`, `is_excluded()` | The unquoted pattern is the exclusion glob itself: it has to be interpreted, not matched literally. |

## Technical choices

**`prebackup` and `postbackup` are called bare, through `run_hook()`.** Neither `run_hook prebackup || die` nor `if ! run_hook prebackup`: placing a function in a condition disables `set -e` throughout its body, so a command failing in the middle would be ignored, the following ones would still run, and the function would return 0. This behaviour has been verified to be identical under `dash` and under `bash`. Called bare, the hook stops the script on the failing command, whose own message goes to the `cron` mail.

`run_hook()` runs the hook in a subshell, so that the user's code does not inherit the internals of the script: descriptor 9, which a daemon started by a hook would keep open, every following run then finding the lock taken; the variable named by an `env:` passphrase, which every program started by a hook would receive (N-R5-1); and `-f`, under which `rm -f /root/dumps/*.sql` would remove nothing (N-R4-1). `set -e` remains active in the subshell. `postbackup` runs whatever the outcome of `tarsnap -c`, with its exit status as `$1`: 2, an archive created with unreadable files, gives a warning and a run that exits with 2, and any other failure stops the script before the rotation (TB-02).

Within a hook, `set -e` only stops the script on a command that fails on a line of its own: not in a pipeline, except in its last command, `dash` having no `pipefail`, nor on the left of `&&` or `||`, nor in the condition of an `if` or a `while`. One command per line, and test what has to be tested (N-R2-11).

**`--quiet --no-print-stats`.** Without `--verbose`, the script passes these two options to Tarsnap. `--quiet` silences a few warnings such as "Removing leading '/'", and `--no-print-stats` overrides a `print-stats` directive in `tarsnap.conf`, which would otherwise print the statistics table on every run. The script only speaks up on errors.

**`printf`, not `echo`.** The behaviour of `echo` on a backslash or on an argument starting with `-` is not specified by POSIX: `dash` interprets escape sequences where `bash` does not. `printf` raises no such issue.

**Long options translated by hand.** POSIX `getopts` only knows single-character options. The long forms, with one or two leading dashes, are rewritten into short ones before `getopts` runs. `tarsnap-diff.sh` maps `--debug` to `-X`, a letter deliberately left out of the documented short options. Every script refuses the operands it does not expect: `getopts` stops at the first operand, so a mistyped option, `dry-run` without its dashes or behind a dash pasted from a document, would otherwise be ignored, and a dry-run asked for would become a real run (N-R1-2).

**Absolute binary paths, checked at startup.** They do not depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`, and a missing binary stops the script before anything else happens. The only exception is `usage()`, which calls `cat` by name: it can be reached through `-h` before the check, and must still display the help.

**`en_US.UTF-8` locale forced.** Tarsnap, `apt` and `date` then produce predictable output. `LANGUAGE` is unset, since GNU gettext would otherwise override `LC_MESSAGES`.

**Why a batch purge is faster.** A single `tarsnap -d` invocation opens one storage reader for all the deletions, with a block cache: what a deletion has already fetched can be served from that cache to the next ones instead of being downloaded again. See `tarsnap_mode_d()` in `tar/glue/tape.c` and `deletetape()` in `tar/multitape/multitape_delete.c`. Tarsnap 1.0.33 already announced a significant speedup of multi-archive deletes.

**`tarsnap-diff.sh`: a single extraction.** The files to compare byte by byte are gathered first, then extracted in one Tarsnap invocation through `-T`, which reads the list of names from a file. One invocation per file would reopen the archive on the server side every time, which becomes ruinous from a hundred files onwards.

**`tarsnap-diff.sh`: dates compared as strings.** `tarsnap -tv --iso-dates` and `find -printf '%TY-%Tm-%Td %TH:%TM:%TS'` both give the local time as `YYYY-MM-DD HH:MM:SS`, once the fractional seconds printed by `find` are truncated. Comparing the strings gives the same verdict as comparing epochs, without forking one `date` per entry: over the 50,000 entries of a real machine, that took several minutes of pure forking.

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
| `env:NAME` | the variable, through `getenv()` | the variable is set and not empty |
| `file:PATH` | a single line, CR or LF stripped, through `readpass_file()` | the file is readable and holds a single non-empty line |

`/dev/tty` is really opened, rather than tested with `[ -r ]`. An empty variable or file is refused as well: Tarsnap would read an empty passphrase and fail on it, later. A file that is not a regular one, a FIFO or a device, is only checked for readability, so as not to consume it. The function sets `PASSPHRASE_HOW` for the verbose message and `PASSPHRASE_WHY` for the error message. Its `eval` only ever sees a variable name validated beforehand, against an explicit list of characters rather than a range such as `[A-Za-z]`, whose content depends on the locale.

**`conf_keyfile()`** asks Tarsnap which key `tarsnap.conf` designates, when `TARSNAP_KEY` is empty. `--dump-config` alone switches Tarsnap to its `--verify-config` mode, which exits before loading the key (`tar/bsdtar.c`, 1.0.41): no passphrase prompt and no network access. The function relies on this output:

- everything on standard error, nothing on standard output, exit status 0;
- the command line first, then a `Reading from config file:` header for each file tried, even a missing one, in reading order, `--configfile` first;
- after each header, the option lines of that file, leading blanks stripped, indented by two spaces;
- the first value wins, hence the first `  keyfile` line after the first header.

The key stays unknown when this answer is not reliable: a non-zero exit (Tarsnap older than 1.0.40, invalid configuration), no `keyfile` line, an argument starting with `~`, which Tarsnap expands from the password database and not from `$HOME`, or an argument containing a blank, which Tarsnap keeps with a warning. Both scripts then only check an `env:` or `file:` method.

## The `--dry-run-metadata` bug

`tarsnap-backup.sh --dry-run` simulates the creation with Tarsnap's `--dry-run`, which rereads all the files and therefore takes as long as a real backup. `--dry-run-metadata`, added in Tarsnap 1.0.41, would be much faster, since it reads no data, but it fails as soon as the chunk cache is populated:

```text
tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
tarsnap: Error writing cached archive entry
```

Reproduced in 1.0.41 on each of the four directories of `BACKUP_DIRS` taken individually, with a `cachedir` coming from a real backup. The same call against a freshly initialised `cachedir` goes through without a hitch, which isolates the cache as the only variable. Nor is it a matter of volume: `/boot` alone is enough.

`print-stats` has nothing to do with it either: the failure also occurs with `--no-print-stats`. Note, however, that a single file passed as an argument is not always enough to trigger the error, even if it is in the cache: the cache has to be able to provide a complete archive entry.

The cause can be seen in the 1.0.41 source. `multitape_write.c:429` sets `no_chunkifiers = (dryrun == 2)`, which deprives the streams initialised on lines 517 to 521 of a chunkifier, whereas the chunk layer `d->C` is created on line 503 with no condition on `dryrun`. As a result, `writetape_ischunkpresent` answers "present" where `writetape_writechunk` returns 0, and `ccache_entry.c:409` treats that 0 as a programmer error. These line numbers refer to the `1.0.41` tag of the Tarsnap repository.

Do not put the option back without checking that this has been fixed upstream. The command that reproduces it, read-only and on a copy of the cache:

```sh
cp -a /usr/local/tarsnap-cache /root/ts-cache-test
tarsnap --cachedir /root/ts-cache-test --dry-run-metadata --no-print-stats -c -f zz-test /boot
echo $?
```
