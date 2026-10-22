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
- **`set -euf`.** Exit on the first error, unset variables are fatal, no globbing on unquoted expansions. `tarsnap-stats.sh` follows its own repository, with `set -eu`.
- **`flock` lock on descriptor 9.** The Tarsnap manual forbids two concurrent create or delete operations with the same key. The lock is held by an open descriptor, so the kernel releases it when the process dies, `kill -9`, OOM and power failure included: no stale lock file, and no race between an existence test and a `touch`.
- **Batch purge in a single call.** Every archive to delete goes to one `tarsnap -d`, with `-f` repeated.
- **Strict naming pattern as the only purge scope.** Only names that exactly match `hostname-YYYY-MM-DD_HH-MM-SS` can be deleted: `.part` archives, snapshots taken with `-s` and every other name stay out of reach.
- **`tarsnap-backup.sh` is never sourced** by the companion tools, only read: sourcing it would run its option parsing, take its lock and, in the end, make a real backup.
- **Read-only modes take no lock.** `--orphans` and `tarsnap-diff.sh` only list or extract, which the Tarsnap manual allows in parallel with any other operation. `rotation-check.sh` does not run Tarsnap at all.
- **No code is removed for the sake of optimisation.** A line that looks redundant is often the trace of a bug that was fixed: removing it is a change of its own, with its own justification.

## Configuration read by the companion tools

`rotation-check.sh` and `tarsnap-diff.sh` read the configuration block of `tarsnap-backup.sh` with `sed`, by variable name:

| Variables | Read by | Expected form |
|---|---|---|
| `DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM` | `rotation-check.sh` | `NAME=` followed by digits, unquoted |
| `TARSNAP_KEY`, `BACKUP_DIRS`, `BACKUP_EXCLUDE` | `tarsnap-diff.sh` | `NAME="..."`, possibly empty |

Hence:

- Renaming one of these variables breaks the tool that reads it.
- Only the first line starting with `NAME=` counts, whereas the shell keeps the last assignment: a second definition further down would make the tools and the backup disagree.
- The value is taken literally: no `$VARIABLE` expansion, and no quoting other than the one above.
- A trailing comment on a string line must not contain a double quote: `read_string` captures everything up to the last `"` of the line.

Both tools look for `/usr/local/sbin/tarsnap-backup.sh` first, then for a `tarsnap-backup.sh` in their own directory, unless `-f` names another one.

## Validation

Every change to a script goes through the following, run from the root of the repository:

```sh
for f in *.sh; do sh -n "$f" && dash -n "$f" && bash -n "$f" || echo "FAILED: $f"; done
shellcheck -s sh *.sh
```

Both commands print nothing when everything is in order. Each mode touched by the change is then run for real, under `dash` and under `bash`, and the documentation is updated in the same commit.

ShellCheck 0.9.0 (Debian Bookworm) and 0.10.0 (Debian Trixie) report nothing. ShellCheck 0.11.0, shipped in trixie-backports and in Forky, also reports SC2329 on `cleanup()` in `tarsnap-diff.sh`: see SC2317 below.

## ShellCheck directives

Each directive sits right above the command it covers, with its reason in a comment. There are thirteen of them, for five codes.

| Code | Where | Why |
|---|---|---|
| SC2086 | `tarsnap-backup.sh`: archive listing in `list_orphans()` and in the rotation, creation, purge. `tarsnap-diff.sh`: archive listing and extraction, two branches each | `$TARSNAP_KEYOPT` and `$TARSNAP_MSGOPT` must vanish from the command line when they are empty, and `$BACKUP_DIRS` is a list. `set -f` rules out globbing. As a consequence, neither the key path nor the entries of `BACKUP_DIRS` may contain whitespace. |
| SC1003 | `key_is_passphrased()`, in both scripts | The backslash belongs to the `i\` command of `sed`: it escapes nothing in the shell. |
| SC2046 | `rotation-check.sh`, replay mode | `set -- $(date ...)` is meant to split the three fields printed by `date`. |
| SC2317 | `tarsnap-diff.sh`, `cleanup()` | The function is only called from the traps, which ShellCheck does not follow, so it believes the body is unreachable. ShellCheck 0.11.0 reports the same situation as SC2329, which the directive does not list yet. |
| SC2254 | `tarsnap-diff.sh`, `is_excluded()` | The unquoted pattern is the exclusion glob itself: it has to be interpreted, not matched literally. |

## Technical choices

**`prebackup` and `postbackup` are called bare.** Neither `prebackup || die` nor `if ! prebackup`: placing a function in a condition disables `set -e` throughout its body, so a command failing in the middle would be ignored, the following ones would still run, and the function would return 0. This behaviour has been verified to be identical under `dash` and under `bash`. Called bare, the function stops the script on the failing command, whose own message goes to the `cron` mail.

**`--quiet --no-print-stats`.** Without `--verbose`, the script passes these two options to Tarsnap. `--quiet` silences a few warnings such as "Removing leading '/'", and `--no-print-stats` overrides a `print-stats` directive in `tarsnap.conf`, which would otherwise print the statistics table on every run. The script only speaks up on errors.

**`printf`, not `echo`.** The behaviour of `echo` on a backslash or on an argument starting with `-` is not specified by POSIX: `dash` interprets escape sequences where `bash` does not. `printf` raises no such issue.

**Long options translated by hand.** POSIX `getopts` only knows single-character options. The long forms, with one or two leading dashes, are rewritten into short ones before `getopts` runs. `tarsnap-diff.sh` maps `--debug` to `-X`, a letter deliberately left out of the documented short options.

**Absolute binary paths, checked at startup.** They do not depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`, and a missing binary stops the script before anything else happens. The only exception is `usage()`, which calls `cat` by name: it can be reached through `-h` before the check, and must still display the help.

**`en_US.UTF-8` locale forced.** Tarsnap, `apt` and `date` then produce predictable output. `LANGUAGE` is unset, since GNU gettext would otherwise override `LC_MESSAGES`.

**Why a batch purge is faster.** A single `tarsnap -d` invocation opens one storage reader for all the deletions, with a block cache: what a deletion has already fetched can be served from that cache to the next ones instead of being downloaded again. See `tarsnap_mode_d()` in `tar/glue/tape.c` and `deletetape()` in `tar/multitape/multitape_delete.c`. Tarsnap 1.0.33 already announced a significant speedup of multi-archive deletes.

**`tarsnap-diff.sh`: a single extraction.** The files to compare byte by byte are gathered first, then extracted in one Tarsnap invocation through `-T`, which reads the list of names from a file. One invocation per file would reopen the archive on the server side every time, which becomes ruinous from a hundred files onwards.

**`tarsnap-diff.sh`: dates compared as strings.** `tarsnap -tv --iso-dates` and `find -printf '%TY-%Tm-%Td %TH:%TM:%TS'` both give the local time as `YYYY-MM-DD HH:MM:SS`, once the fractional seconds printed by `find` are truncated. Comparing the strings gives the same verdict as comparing epochs, without forking one `date` per entry: over the 50,000 entries of a real machine, that took several minutes of pure forking.

**`tarsnap-diff.sh`: `LC_ALL=C` on `sort` and `join`.** `join` silently misbehaves when the collation order of its inputs is not its own. `sort -u` on the key also guards against a path present twice, which would otherwise produce the Cartesian product of the duplicates.

**`tarsnap-diff.sh`: the header of the log.** It carries the counters, so it can only be written last: it is built in a file next to the log, followed by the accumulated details, then renamed over the log. The rename stays within the same file system, hence it is atomic.

**Passphrase detection.** `key_is_passphrased()` follows `lib/keyfile/keyfile.c` of Tarsnap: once comments and blank lines are skipped, the base64 of an encrypted key starts with `c2NyeXB0`, the encoding of `scrypt`, so no decoding is needed. `sed` returns a fixed verdict rather than the line, so the NUL bytes of a raw binary key never reach the shell. Known limitation: a key file whose lines end with a lone CR is seen as a single comment line, hence reported as not protected; `tarsnap-keygen` and `tarsnap-keymgmt` write LF, and CRLF is handled. The function exists in `tarsnap-backup.sh` and in `tarsnap-diff.sh`, and must stay identical in both.

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
