[![License: CC0](https://img.shields.io/badge/license-CC0_1.0-lightgrey.svg?style=plastic)](https://creativecommons.org/publicdomain/zero/1.0/)
![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=plastic\&logo=Debian\&logoColor=white)
![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)

![shellcheck](https://img.shields.io/badge/shellcheck-clean-brightgreen?style=plastic)
![GitHub release](https://img.shields.io/github/v/release/deuza/tarsnap-tools?label=release&style=plastic)
[![GitHub last commit](https://img.shields.io/github/last-commit/deuza/tarsnap-tools?style=plastic)](https://github.com/deuza/tarsnap-tools/commits/main)
![GitHub commit activity](https://img.shields.io/github/commit-activity/t/deuza/tarsnap-tools?style=plastic)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/deuza/tarsnap-tools?style=plastic)


# tarsnap-tools

Tarsnap Tools is a suite of utilities for Tarsnap, used daily by the author.

It relies on the [Tarsnap](https://www.tarsnap.com/) backup tool, followed by a grandfather/father/son rotation.  
It is written for Debian, in strictly POSIX `sh`, with no dependency on `bash` but with dependencies on Debian.

The main script is `tarsnap-backup.sh`, which takes care of your backups: once it is configured, there is no need to touch it again.  
It prepares what needs to be prepared, creates a dated archive, then purges the old ones according to a three-tier retention scheme.

Three tools come with it (none of them creates or deletes a single archive):

| Script | Role |
|---|---|
| `tarsnap-backup.sh` | backup and grandfather / father / son rotation |
| `rotation-check.sh` | checks the retention configuration, without touching Tarsnap |
| `tarsnap-diff.sh` | compares a snapshot with the current state of the system |
| `tarsnap-stats.sh` | sizes, deduplication and storage cost |

These scripts were developed and tested with Tarsnap 1.0.41 on Debian Trixie, and are used daily by the author.  
They are extensively commented, so that they can be understood, modified, adapted, and so on.

**NOTE: Take the time to read this README calmly and in full before starting the installation. Usage and configuration are fairly simple, but they require an understanding of what the different tools do.**

## Contents

- [What the script does](#what-the-script-does)
- [The retention scheme](#the-retention-scheme)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Preparing and cleaning up around the backup](#preparing-and-cleaning-up-around-the-backup)
- [Usage](#usage)
- [Archives outside the rotation](#archives-outside-the-rotation)
- [Checking your retention configuration](#checking-your-retention-configuration)
- [Comparing a snapshot with the system](#comparing-a-snapshot-with-the-system)
- [Statistics and storage cost](#statistics-and-storage-cost)
- [Design guarantees](#design-guarantees)
- [Technical choices](#technical-choices)
- [Known limitations](#known-limitations)
- [Restoring](#restoring)
- [License](#license)

## What the script does

On every run, in this order:

1. It calls `prebackup`, the function that prepares the ground. By default it regenerates the inventory of installed packages, `dpkg --get-selections` and `apt list --installed`, into two files that are themselves included in the backup. Restoring a machine without knowing what was installed on it is an avoidable waste of time. This is also where you will put your database dumps and your calls to external scripts.
2. It creates a Tarsnap archive named `hostname-YYYY-MM-DD_HH-MM-SS`.
3. It calls `postbackup`, the counterpart of the first one: cleanup of temporary dumps, notification, restart of a service.
4. It lists the existing archives and deletes those that meet none of the three retention criteria.

The order is deliberate: the new archive is created **before** anything is destroyed. If Tarsnap fails, because of the network, the quota or the key, `set -e` aborts the script and no archive is deleted.  
The *worst* possible case is therefore "old archives pile up", but never "I purged and I have nothing new".

## The retention scheme

### The principle

Grandfather/Father/Son `(GFS)` is a magnetic tape rotation scheme, several decades older than online backups (like me :).  
The idea: the older a backup is, the less granularity is needed. So all recent backups are kept, then one per week, then one per month.

[Wikipedia article](https://en.wikipedia.org/wiki/Backup_rotation_scheme#Grandfather-father-son)

### The windows are cumulative

This is the point that deserves your attention, because the two possible readings give very different results.

The three windows **follow one another** instead of overlapping. Each tier takes over where the previous one stops. With the default values:

| Tier | Variable | Keeps | Covers |
|---|---|---|---|
| Son | `DAILY=90` | all archives | from 0 to 90 days |
| Father | `WEEKLY=12` | those falling on a `DOW` | from 90 to 174 days |
| Grandfather | `MONTHLY=48` | those falling on a `DOM` | from 174 to 1635 days |

The total coverage is therefore `DAILY` days **plus** `WEEKLY` weeks **plus** `MONTHLY` months, i.e. nearly four and a half years with the shipped values.

The other possible reading, where the three windows would be counted from now rather than one after the other, was not retained.  
It requires the user to respect the invariant `DAILY < WEEKLY*7 < MONTHLY*30`, otherwise a tier silently becomes unreachable.

With `DAILY=90` and `WEEKLY=12`, the 84 days of the weekly window would fit entirely within the 90 days of the daily window, and the father tier would never keep anything, without the slightest error message. Cumulative windows make this invariant structural: there is nothing left to check.

### An archive is kept if it meets at least one criterion

The three tests are independent and evaluated in order. The first one that answers "yes" wins, but none of them excludes the others.  
In practice, an archive dated the 1st of the month is kept by the monthly tier even if it still falls within the date range of the weekly tier and is not a Monday.

This is the expected behaviour: the tiers define reasons to keep, not exclusive slices.

### What it looks like in practice

Over five years of daily backups, with the default values:

```
  son         (daily)    : 90
  father      (weekly)   : 12
  grandfather (monthly)  : 50
  deleted                : 1673
  ----------------------------------
  kept in total          : 152
```

One hundred and fifty-two archives kept out of one thousand eight hundred and twenty-five.  
These figures are those of the provided diagnostic script `rotation-check.sh`, not an estimate!

### Why purge so little?

Tarsnap deduplicates your data.  
An archive that brings no new data only costs its non-deduplicated metadata, roughly 1 kB, plus 1 byte per file and 1 byte per MB of data.

In most cases this stays under 10 kB, i.e. less than $0.0000025 per month at Tarsnap's rate of 250 picodollars per byte-month.  
You can therefore be far more generous than in the days of tapes, when the marginal cost of a backup was the price of a tape.

[More about deduplication](https://www.tarsnap.com/deduplication-explanation)

## Requirements

Debian, or any GNU/Linux distribution derived from it.  
It assumes `usrmerge`, hence the base binaries under `/usr/bin`, and it calls `dpkg` and `apt` for the package inventory.  
The shell syntax, on the other hand, is strictly POSIX `sh`: no dependency on `bash`, and everything runs under the `dash` that Debian installs as `/bin/sh`, as well as under `bash` and other POSIX shells.

You need, in this order:

**A Tarsnap account and a key** generated by `tarsnap-keygen`.

**The tarsnap client**, available from [the download page](https://www.tarsnap.com/download.html).

(Binary .deb packages are only provided for i386 and amd64. On any other architecture, for example a Raspberry Pi in `aarch64` like mine, you will have to go through [the .deb build page](https://www.tarsnap.com/pkg-deb.html#tarsnap-source-package).)

Note: it is the `libext2fs-dev` package that provides `ext2fs/ext2_fs.h`, required by tarsnap, not to be confused with `linux/ext2_fs.h`!

**The base tools**, already present on a standard Debian: `flock` (util-linux), `date` and `sed` (coreutils and sed), `dpkg` and `apt`.

**The `en_US.UTF-8` locale must be generated**, for predictable output from tarsnap, `apt` and `date`. The script refuses to start without it:

```sh
dpkg-reconfigure locales
```

### Other systems

The script is not portable as is.
It should run on another "Debian-like" distribution.

If you want to port it, the `dpkg` and `apt` inventory is the first thing to replace.  
Feel free to drop me a line!

## Installation

```sh
git clone https://github.com/deuza/tarsnap-tools.git
cd tarsnap-tools
cp tarsnap-backup.sh /usr/local/sbin/
chown root:root /usr/local/sbin/tarsnap-backup.sh
chmod 0700 /usr/local/sbin/tarsnap-backup.sh
```

The script runs as root and reads the Tarsnap key: 0700 and nothing more.

The other three scripts are optional extras and do not need to be installed in `/usr/local/sbin/`.  
Make them executable and run them from the cloned repository:

```sh
chmod +x rotation-check.sh tarsnap-diff.sh tarsnap-stats.sh
```

- `rotation-check.sh` simulates your retention configuration, or replays it against your real data.
- `tarsnap-diff.sh` compares a snapshot with the current state of the system.

Both fetch their configuration from `tarsnap-backup.sh`, at the expected paths:
- First `/usr/local/sbin/tarsnap-backup.sh`
- Then, failing that, a `tarsnap-backup.sh` next to them, in their own directory.

- `tarsnap-stats.sh`, for its part, reads none of this: it relies on your `tarsnap.conf` and has no configuration of its own.

Then edit the configuration block at the top of the file (next section), check the syntax, and do a trial run with `--dry-run`, which prevents any snapshot from being created:

```sh
sh -n /usr/local/sbin/tarsnap-backup.sh
/usr/local/sbin/tarsnap-backup.sh --dry-run --verbose
```

Once satisfied, put it in root's crontab:

```
2 0 * * * /usr/local/sbin/tarsnap-backup.sh
```

Or in the `/etc/crontab` file:

```
02 00   * * *   root /usr/local/sbin/tarsnap-backup.sh
```

Without `--verbose`, the script is silent in normal operation.  
Only errors and warnings go to standard error, hence into the `cron` mail, or elsewhere depending on your setup.

## Configuration

Everything is set in the block at the top of the file, between `CONFIGURATION` and `END OF CONFIGURATION`.

### Binary paths

`TARSNAP_BIN`, `DATE_BIN`, `UNAME_BIN`, `LOCALE_BIN`, `GREP_BIN`, `DPKG_BIN`, `APT_BIN`, `FLOCK_BIN`.

The binary paths are hardcoded so as not to depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`.  
The shipped values are those of Debian with `usrmerge`, hence everything under `/usr/bin`. At startup, the script checks that each of them is executable, and refuses to run otherwise.

### Tarsnap

`TARSNAP_KEY`: the path of the Tarsnap key. Leave the variable empty to rely on the `keyfile` declared in `tarsnap.conf`.  
A single key is enough: on the Tarsnap side, the delete permission implies the read permission, so a separate read-only key would only be a strict subset.

The `cachedir`, on the other hand, is not passed on the command line. It is read from `tarsnap.conf`.

You can check all of this with the following command:

```
root@foo:~/tarsnap-backup# tarsnap --dump-config
Command-line:
  tarsnap --dump-config
Reading from config file: /root/.tarsnaprc
Reading from config file: /root/.config/tarsnap/tarsnap.conf
Reading from config file: /etc/tarsnap.conf
  cachedir /usr/local/tarsnap-cache
  keyfile /root/tarsnap.key
  nodump
  print-stats
  checkpoint-bytes 1G
root@foo:~/tarsnap-backup#
```

You can also check your Tarsnap configuration:

```
root@foo:~/tarsnap-backup# tarsnap --verify-config
root@foo:~/tarsnap-backup# echo $?
0
root@foo:~/tarsnap-backup#
```

### Backup contents

- `BACKUP_DIRS`: directories to include, space-separated.  
- `BACKUP_EXCLUDE`: exclusion patterns, space-separated.

Two forms are accepted:

1. An absolute path, for example `/var/www/html/APOD`, hence anchored and without side effects.
2. A glob pattern, for example `*/tmp/*`, passed as is to Tarsnap.

Tarsnap uses the `bsdtar` syntax and strips the leading `/` from entry names: for absolute paths, the script does the conversion and generates the two patterns needed, the one for the directory and the one for its contents.

### Retention

`DAILY`, `WEEKLY`, `MONTHLY`, `DOW`, `DOM`. See [the retention scheme](#the-retention-scheme) above.

`DOW` is 0 for Sunday, 1 for Monday. `DOM` is the day of the month kept, 1 by default.  
Avoid 29, 30 and 31 as `DOM`: the months that do not contain them will not get any archive kept!

Setting `WEEKLY` or `MONTHLY` to 0 disables the corresponding tier: the diagnostic script `rotation-check.sh` will warn you about it.

### Miscellaneous

`LOCK_FILE`: run lock, in `/run` by default.  
Neither `/tmp` nor `/run/lock`, which are mode 1777: any local user could hold the lock there and block your backups indefinitely!!!

`PKG_SELECTIONS` and `PKG_LIST`: the two inventory files produced by `prebackup`.  
Put them in a directory covered by `BACKUP_DIRS`, otherwise they will not make it into the archive.

## Preparing and cleaning up around the backup

Two functions frame the creation of the archive. They are located right after the configuration block and are meant to be edited.

### `prebackup`

Everything that must be prepared before Tarsnap reads the files: inventories, database dumps, configuration export, call to an external script.  
Shipped with the package inventory and a series of commented-out examples, to adapt to your needs:

```sh
prebackup() {
    say "Taking inventory of installed packages."
    "$DPKG_BIN" --get-selections > "$PKG_SELECTIONS"
    "$APT_BIN" list --installed 2>/dev/null > "$PKG_LIST"

    # say "Dumping the MySQL databases."
    # /usr/bin/mysqldump --all-databases --single-transaction --quick \
    #     --events --routines > /root/dumps/mysql-all.sql

    return 0
}
```

Declare the absolute path of your binaries at the top of the script, like the others, rather than relying on `PATH`.  
And for MySQL, the credentials go in a `~/.my.cnf` with mode 0600, never on the command line, where `ps` would make them visible to every user of the machine.

### `postbackup`

The counterpart, run once the archive has been created, snapshot included, and before the rotation.  
Cleanup of temporary dumps, notification, restart of a service stopped by `prebackup`.

It is empty by default, apart from its commented-out examples.

### The two rules to remember

**The function must return 0.**

Any other value, and any command failing inside it, stops the script:  
- For `prebackup`, this happens **before** the archive is created, hence before any deletion: better to back up nothing than to back up a half-dumped database.  
- For `postbackup`, the archive is already in place and it is the rotation that gets skipped, so the old archives pile up.

In both cases, the script fails in the right direction.

### Both functions also run in `--dry-run` mode

This is intentional: a simulation that did not prepare the same files would not simulate much, since those files are exactly what Tarsnap is supposed to read.  
A practical consequence, better not discovered in production: if you put a dump of several gigabytes in them, comment it out before running trial after trial, otherwise every `--dry-run` replays it in full.

## Usage

```
usage: tarsnap-backup.sh [-d|-n|--dry-run] [-v|--verbose] [-h|--help]
       tarsnap-backup.sh [-s|--snapshot-name] NAME
       tarsnap-backup.sh [-o|--orphans]
```

`-d`, `-n`, `--dry-run`: full simulation. Nothing is created or deleted, and the purge command that would be executed is displayed.  
Beware: the creation is simulated by `tarsnap --dry-run`, which really reads the files: it takes as long as a real run.

**Note that the script's `-d` means "delete nothing", the exact opposite of Tarsnap's `-d`: `-n` is accepted as a synonym and remains the less ambiguous form.**

`-v`, `--verbose`: details the decision made for each archive, and passes `-v` to Tarsnap.

`-s NAME`, `--snapshot-name NAME`: creates an archive suffixed with `NAME`, then exits without rotating.  
The suffix takes it out of the pattern tested by the purge, so it becomes permanently untouchable by the script.  
**This is what to use before going into production, for example.**

The allowed characters are `A-Z`, `a-z`, `0-9`, `_` and `-`. The `--snapshot-name=NAME` form is also accepted.

`-o`, `--orphans`: lists the archives beyond the reach of the rotation, then exits. See the next section.

`-h`, `--help`: displays the help.

## Archives outside the rotation

The rotation only ever touches the archives whose name exactly matches `hostname-YYYY-MM-DD_HH-MM-SS`.  
Everything else is invisible to it, and will stay that way.  
This is a guarantee, but it is also a way of piling up, without noticing, orphaned archives that nothing cleans up any more.

```sh
tarsnap-backup.sh --orphans
```

The option is read-only: it creates nothing, deletes nothing, and does not even take a lock.  
*You can therefore call it while a backup is running in the background.*

It distinguishes two families, for two different reasons:

**- Orphaned snapshots:**  
Their names do not match the pattern of the snapshots created by `tarsnap-backup.sh`, so the purge excludes them outright.

This covers any snapshot created with the Tarsnap key under another name: the purge touches **ONLY** what EXACTLY matches the pattern **`hostname-YYYY-MM-DD_HH-MM-SS`**

**- Partial archives:**  
Suffixed `.part`, they are the leftovers of an interrupted run from which Tarsnap recovered a checkpoint.

They count for deduplication and may contain data found nowhere else.  
The script already reports them on standard error at every rotation. The `--orphans` option gathers them so that you can decide with a cool head.

For each family, the matching delete command is displayed, ready to be reviewed and then pasted.  
It will never be run by the script:

```
--- Orphans: name outside the pattern, never purged ---
  foo-2026-01-10_03-00-00_before-prod
  old-manual-backup
  bar-2024-02-01_02-00-00

  Delete command, review before pasting:
  /usr/bin/tarsnap --keyfile /root/tarsnap.key -d -f foo-2026-01-10_03-00-00_before-prod -f old-manual-backup -f bar-2024-02-01_02-00-00
```

## Checking your retention configuration

The repository includes the `rotation-check.sh` script, which replays the decision logic of the rotation. It touches neither Tarsnap, nor the network, nor any archive.  
The retention values are taken from the `tarsnap-backup.sh` file.

The search order is `/usr/local/sbin/tarsnap-backup.sh`, then, failing that, a `tarsnap-backup.sh` next to the script, in its own directory (which covers the case of a freshly cloned repository).

The `-f` option bypasses both.  
The file is never sourced by the script, only read: sourcing it would trigger its option parsing, its lock and, in the end, a real backup.

The tool is essential on a recent machine: as long as all your archives fit within the daily window, a real `--dry-run` will report "Nothing to purge." and will prove strictly nothing.

Simulate five years of daily backups with your configuration:

```sh
./rotation-check.sh
```

Compare another setting without modifying anything:

```sh
./rotation-check.sh -d 30 -w 26 -m 60
```

Replay the decision on your **real** archives:

```sh
tarsnap --list-archives | ./rotation-check.sh -l -
```

The output starts by showing where the configuration comes from, then shows the three ranges:

```
configuration read from /usr/local/sbin/tarsnap-backup.sh

daily      DAILY=90   all              from     0 to    90 d
weekly     WEEKLY=12  DOW=1            from    90 to   174 d
monthly    MONTHLY=48 DOM=1            from   174 to  1635 d
```

## Comparing a snapshot with the system

The repository also includes the `tarsnap-diff.sh` script, which compares a Tarsnap snapshot with the current state of the machine and tells you what has changed since.

It sticks to the scope actually backed up: `BACKUP_DIRS`, `BACKUP_EXCLUDE` and `TARSNAP_KEY` are read from `tarsnap-backup.sh`, with the same search order as `rotation-check.sh` and the same precaution: the file is never sourced.

No archive is touched.  
Only `-tv` and `-x` are used, both read-only on the Tarsnap side: *"Extracting or listing archives may be performed in parallel with any other operation"*.  
The script therefore takes no lock, and you can call it while a backup is running.

### The four categories

The notation is that of `diff`.

| Prefix | Category | Meaning |
|---|---|---|
| `<` | deleted | present in the snapshot, absent from the system |
| `>` | new | present on the system, absent from the snapshot |
| `=` | identical | present on both sides, content deemed identical |
| `*` | modified | present on both sides, content deemed different |

Without any option, all four are included. `-d`, `-n`, `-i` and `-m` select them and can be combined: `-dn`, for example, will only show the deleted and the new files.

### How the verdict is reached

This is the point that deserves your attention, because it determines what the tool costs you.

The listing of an archive gives the type, the size and the modification date of each entry. Nothing else, and above all no checksum!  
Comparing two contents therefore requires fetching the one in the snapshot, which costs time and billed bandwidth. Hence three cases, only one of which touches the network.

| Situation | Verdict | Network |
|---|---|---|
| Different sizes | `*` modified | none |
| Equal sizes, equal `mtime` | `=` identical | none |
| Equal sizes, different `mtime` | settled byte by byte | download |

Two different sizes imply two different contents: the case is settled for free, and it is by far the most frequent one.

Two matching sets of metadata count as `=`, by a heuristic acknowledged as such. A file rewritten with exactly the same size, whose `mtime` was then reset to its original value, would slip through. It has to be done on purpose, and `--strict` is there for those who are not satisfied with that.

That leaves the ambiguous case, the only one that justifies an actual read.  
The file is downloaded, then compared byte by byte: this is what eliminates the false `*` of a file that was merely touched by a `touch`, a changed `chmod`, a restore, and so on.

The files to download are first gathered, then extracted in **a single** Tarsnap invocation, through the `-T` option, which reads the list of names from a file.  
One invocation per file would reopen the archive on the server side every time, which becomes ruinous from a hundred files onwards.

### Strict mode

`-S` downloads and compares byte by byte **all** the common regular files, including those whose metadata match.  
It is the only absolute guarantee, but it downloads the whole common part of the snapshot.

**Keep it for one-off checks, and certainly not for `cron`!!**

The extraction is done in a temporary directory under `${TMPDIR:-/tmp}`. If `/tmp` does not have enough room, point `TMPDIR` elsewhere:

```sh
TMPDIR=/var/tmp ./tarsnap-diff.sh -S www-2026-08-27_00-02-02
```

Without `-i` or `-m`, `-S` has nothing to reinforce: it is then inert, and the script tells you so rather than silently ignoring it.

### Asking for a single category costs less

The download only serves to tell `=` from `*`. If you asked for neither, it is short-circuited, and the run becomes purely local once the listing has been obtained.

```sh
./tarsnap-diff.sh -d www-2026-08-27_00-02-02       # no download
./tarsnap-diff.sh -dn www-2026-08-27_00-02-02      # no download either
```

The `<` and `>` counters remain exact in every case, as they depend on no download.  
The `=` and `*` counters, on the other hand, then fall back on the metadata alone: they are flagged as indicative, on screen as well as in the log.

The other steps cannot be skipped. "deleted" and "new" are deduced by matching the two complete inventories: the archive must therefore be listed **and** the system walked, whatever the requested category.

### The log

On a machine that has been in production for some time, the diff runs to tens of thousands of lines, and a terminal's buffer is not an analysis tool.  
The details are therefore written to a file, `/var/log/tarsnap-diff.sh-<snapshot>.log` (by default), and only the numeric summary is displayed:

```
root@foo:~# ./tarsnap-diff.sh foo-2026-07-27_00-02-05
Diff of foo-2026-07-27_00-02-05

  deleted     (<) : 9
  new         (>) : 3325
  identical   (=) : 30659
  modified    (*) : 48
  --------------------------------
  total           : 34041

Details: /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log
```

The log carries the same figures at the top, so that a `head -11` sums up the whole context for you:

```
root@foo:~/tarsnap-tools# head -11 /var/log/tarsnap-diff.sh-foo-2026-08-20_00-02-02.log
# tarsnap-diff.sh
# snapshot    : foo-2026-08-20_00-02-02
# date        : 2026-09-19 00:14:34
# directories : /root /boot /var/www /etc
# exclusions  : */tmp/* /var/www/html/APOD
# mode        : hybrid, byte by byte if equal size and different mtime
#
# deleted    (<) : 9
# new        (>) : 3417
# identical  (=) : 30663
# modified   (*) : 52
root@foo:~/tarsnap-tools#
```

It is plain text, with no ANSI sequences: a file made to be grepped:

```sh
grep '^\*' /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log   # the modified files
grep -c '^>' /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log # how many new files
```

The detail lines are written as they come, to a descriptor kept open, so you can follow the diff being built from another terminal:

```sh
tail -f /var/log/tarsnap-diff.sh-foo-2026-07-27_00-02-05.log
```

The header, of course, can only be written once the counters are known.  
It is therefore prepended at the very end, by rewriting into a neighbouring file and then renaming it.  
The operation is atomic, the log is never left truncated, but it changes the inode: a `tail -f` started during the run follows the old file, and will have to be restarted to see the header.

Do not put the log in a directory covered by `BACKUP_DIRS`: it would show up in its own diff as a new file.  
The script warns you if you give it an absolute path that falls inside one.

### Options and examples

```
usage: tarsnap-diff.sh [-d] [-n] [-i] [-m] [-S] [-v] [-e "patterns"]
                       [-l log] [-f script] [--debug] SNAPSHOT
```

| Option | Effect |
|---|---|
| `-d`, `--deleted` | includes the files deleted since the snapshot |
| `-n`, `--new` | includes the new files, absent from the snapshot |
| `-i`, `--identical` | includes the identical files |
| `-m`, `--modified` | includes the modified files |
| `-S`, `--strict` | compares **all** the common files byte by byte |
| `-v`, `--verbose` | details the progress on standard error |
| `-e`, `--exclude` | overrides `BACKUP_EXCLUDE` |
| `-l`, `--log` | path of the log |
| `-f`, `--file` | path of `tarsnap-backup.sh` |
| `--debug` | execution trace, and the temporary directory is kept |
| `-h`, `--help` | displays the help |

`SNAPSHOT` is the exact name of an existing archive, as listed by `tarsnap --list-archives`.

A few examples:

```sh
./tarsnap-diff.sh foo-2026-08-27_00-02-02                    # all four categories
./tarsnap-diff.sh -m foo-2026-08-27_00-02-02                 # modified only
./tarsnap-diff.sh -dn foo-2026-08-27_00-02-02                # deleted and new
./tarsnap-diff.sh -S -m foo-2026-08-27_00-02-02              # modified, strict check
./tarsnap-diff.sh -e "*/cache/*" foo-2026-08-27_00-02-02     # other exclusions
```

**The `-e` option deserves a detailed explanation:**  
The exclusions in force when the snapshot was taken cannot be reconstructed: the script will necessarily apply today's...  
If they have changed since, `-e` is precisely what lets you replay the old exclusions.

### tarsnap-diff.sh limitations

**Directories and symbolic links: only their presence is compared.**  
If they exist on both sides, they are counted as `=`, with no notion of modification.

The listing does not provide what is needed to reliably judge a change of link target or of directory permissions.  
Devices, sockets and named pipes are ignored, and have no business being in `BACKUP_DIRS`.

**The system is alive during the walk:** two successive runs may differ by one without anything abnormal having happened: a temporary file created and then deleted between the two is enough.

**The same GNU dependencies as the rest of the suite:** `find -printf`, `sed -i` and the `%T` extension of the `find` formats.

**The comparison is about content, not metadata:** a file whose permissions or owner alone have changed comes out as `=`.

## Statistics and storage cost

`tarsnap-stats.sh` completes the suite on the accounting side: number of snapshots, sizes, deduplication ratio and actual monthly cost.

```
root@foo:~# ./tarsnap-stats.sh
All archives:
  Snapshots:        46
  Total size:       647.23 GB
  Compressed size:  619.83 GB
  Ratio:            95.8%

Unique data:
  Total size:       9.21 GB
  Encoded size:     8.57 GB
  Ratio:            93.0%

Storage cost:
  Monthly:          $2.1417
  Daily:            $0.071391 (30-day month)
  (250 pUSD/byte/month of encoded data)
root@foo:~#
```

This is where your retention choice gets its price tag:  
The [Why purge so little?](#why-purge-so-little) section explains why a redundant archive costs almost nothing.  
This tool gives you the "almost" for your own account.

A single network call is made, `--list-archives`, and only to count the snapshots: `--print-stats` is computed locally from the `cachedir`.  
Do not put it in `cron` for all that: `--list-archives` downloads and decrypts the metadata of every archive on each run, for figures that only change when an archive is created or deleted.

This script has its own repository, [github.com/deuza/tarsnap-stats](https://github.com/deuza/tarsnap-stats), where its full documentation is maintained: options, exit codes, and how to check each figure by hand against the raw output of Tarsnap.

It is also listed on [Tarsnap's helper scripts page](https://www.tarsnap.com/helper-scripts.html), in the *Other Tarsnap-related tools* section.  

## Design guarantees

- **Creation before deletion.** Never the other way round, under any circumstances.
- **`set -euf`.** Exit on the first error, unset variables are fatal, no globbing on unquoted expansions.
- **`flock` lock on descriptor 9.** The Tarsnap manual forbids two concurrent create or delete operations with the same key. The lock is held by an open descriptor, so the kernel releases it when the process dies, including on `kill -9`, OOM or power failure. No stale file to clean up, and no possible race, unlike an existence test followed by a `touch`.
- **Batch purge in a single call.** The manual allows `-f` to be repeated in `-d` mode, and Tarsnap caches the metadata, which noticeably speeds up the purge of several archives.
- **Strict naming pattern as a safeguard.** Anything that does not exactly match the pattern is never deleted.

## Technical choices

**The `prebackup` and `postbackup` functions are called bare, without any condition on their return status.**

The `set -e` at the top of the script stops it on the failing command: it does not go on to create the snapshot.  
No home-made error message, just the one from the failing command: this is much safer, because every error is caught this way.

Before adding a command or a script to one of these blocks, make sure it runs correctly, by using the `--dry-run` option and checking that nothing turns up in the `cron` mail, or in `--verbose` mode.

---

### Tarsnap's `--dry-run`, not `--dry-run-metadata`

The latter, added in Tarsnap 1.0.41, would nevertheless be much faster: it reads no data, whereas `--dry-run` rereads all the files and therefore takes as long as a real backup.  
It is ruled out because it fails as soon as the chunk cache is populated.

```
tarsnap: Programmer error: writetape_writechunk unexpectedly returned 0
tarsnap: Error writing cached archive entry
```

Reproduced in 1.0.41 on each of the four directories of `BACKUP_DIRS` taken individually, with a `cachedir` coming from a real backup.  
The same call against a freshly initialised `cachedir` goes through without a hitch, which isolates the cache as the only variable. Nor is it a matter of volume: `/boot` alone is enough.

And `print-stats` has nothing to do with it:  
The failure also occurs with `--no-print-stats`. Note, however, that a single file passed as an argument is not always enough to trigger the error, even if it is in the cache: the cache has to be able to provide a complete archive entry.

The cause can be seen in the 1.0.41 source. `multitape_write.c:429` sets `no_chunkifiers = (dryrun == 2)`, which deprives the streams initialised on lines 517 to 521 of a chunkifier, whereas the chunk layer `d->C` is created on line 503 with no condition on `dryrun`. As a result, `writetape_ischunkpresent` answers "present" where `writetape_writechunk` returns 0, and `ccache_entry.c:409` treats that 0 as a programmer error.

Do not put the option back without checking that this has been fixed upstream.  
The command that reproduces it, read-only and on a copy of the cache:

```sh
cp -a /usr/local/tarsnap-cache /root/ts-cache-test
tarsnap --cachedir /root/ts-cache-test --dry-run-metadata --no-print-stats -c -f zz-test /boot
echo $?
```

---

**`--quiet --no-print-stats`.** These Tarsnap arguments make the script run silently, without systematically printing the statistics table at the end of each run.  
The only time the script gets talkative is when an error occurs.

**`printf` and not `echo`.** The behaviour of `echo` on a backslash or on an argument starting with `-` can vary from one shell to another, whereas `printf` raises no such issue.

**Long options translated by hand.** POSIX `getopts` only knows single-character options.  
The script rewrites the long forms into short ones before running `getopts`, with one or two dashes accepted.

## Known limitations

**The rotation is anchored on `uname -n`:** renaming the machine, or switching from the short name to the fully qualified name, takes all the earlier archives out of the tested pattern.  
They become immortal and will have to be purged by hand: `--orphans` will list them for you.  
If you are planning a rename, clean up first, or accept that the history will be kept.

**The script is specific to Debian-like distributions:** `dpkg` and `apt` are among the mandatory binaries, and the `date` calls rely on the GNU `-d` and `%-d` extensions.  
Elsewhere, it will refuse to start until the configuration block and the package inventory have been adapted.

**Tarsnap exit code 2 is not singled out:** Tarsnap uses it to report an error that occurred after the server-side state had already been modified.  
`set -e` treats it like any other error.

## Restoring

A backup that has never been restored is not a backup :)

Make a habit of checking, for example once a quarter:

```sh
tarsnap --list-archives                                # pick an archive from the list
tarsnap -tv -f hostname-YYYY-MM-DD_HH-MM-SS            # inspect its contents
mkdir /tmp/restore && cd /tmp/restore                  # create a temporary directory for the restore
tarsnap -x -f hostname-YYYY-MM-DD_HH-MM-SS etc/fstab   # restore only /etc/fstab from the snapshot, into the current directory
```

**Tarsnap strips the leading `/` from entry names (like `bsdtar`), so the paths to extract are relative: `etc/fstab`, not `/etc/fstab`.**  
The restored file will therefore end up in `/tmp/restore/etc/fstab`: it will **NEVER** overwrite the original!

## License

[![CC0](https://mirrors.creativecommons.org/presskit/buttons/88x31/svg/cc-zero.svg)](https://creativecommons.org/publicdomain/zero/1.0/)

`CC0 1.0 Universal` -- Public Domain -- [LICENSE](LICENSE).

`tarsnap-stats.sh`, which comes from [its own repository](https://github.com/deuza/tarsnap-stats)


<p align="center">With ❤️ by <a href="https://github.com/deuza">DeuZa</a></p>
