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

Three tools come with it, and none of them creates or deletes a single archive. The whole suite:

| Script | Role |
|---|---|
| `tarsnap-backup.sh` | backup and grandfather / father / son rotation |
| `rotation-check.sh` | checks the retention configuration, without touching Tarsnap |
| `tarsnap-diff.sh` | compares a snapshot with the current state of the system |
| `tarsnap-stats.sh` | sizes, deduplication and storage cost |

These scripts were developed and tested with Tarsnap 1.0.41 on Debian Trixie, and are used daily by the author.  
They are extensively commented, so that they can be understood, modified, adapted, and so on, and [HACKING.md](HACKING.md) gathers the rules they follow and the reasons behind the less obvious choices.

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
The exact count depends on the day you run it, since the 1sts of the month do not always fall at the same place in the windows: simulated on every day of 2026 and 2027, it stays between 150 and 153.

### Why purge so little?

Tarsnap deduplicates your data.  
An archive that brings no new data only costs its non-deduplicated metadata, roughly 1 kB, plus 1 byte per file and 1 byte per MB of data.

In most cases this stays under 10 kB, i.e. less than $0.0000025 per month at Tarsnap's rate of 250 picodollars per byte-month.  
You can therefore be far more generous than in the days of tapes, when the marginal cost of a backup was the price of a tape.

[More about deduplication](https://www.tarsnap.com/deduplication-explanation)

## Requirements

Debian, or any GNU/Linux distribution derived from it.  
It assumes `usrmerge`, hence the base binaries under `/usr/bin`, and it calls `dpkg`, `apt` and `apt-mark` for the package inventory.  
The shell syntax, on the other hand, is strictly POSIX `sh`: no dependency on `bash`, and everything runs under the `dash` that Debian installs as `/bin/sh`, as well as under `bash` and `busybox sh`.  
`posh` is the exception: it accepts the syntax but cannot run `tarsnap-backup.sh` nor `tarsnap-diff.sh`, see [HACKING.md](HACKING.md#validation).

You need, in this order:

**A Tarsnap account and a key** generated by `tarsnap-keygen`.

**The tarsnap client**, version 1.0.40 or later, available from [the download page](https://www.tarsnap.com/download.html).  
Without `--verbose`, every run passes it `--no-progress-bytes`, which older versions do not know: see [Known limitations](#known-limitations).

(Binary .deb packages are only provided for i386 and amd64. On any other architecture, for example a Raspberry Pi in `aarch64` like mine, you will have to go through [the .deb build page](https://www.tarsnap.com/pkg-deb.html#tarsnap-source-package).)

Debian itself has shipped a `tarsnap` package in its `non-free` section since 2026, for most architectures including `arm64`, but at the time of writing only in testing (Forky) and unstable (Sid), not in Trixie.

Note: it is the `libext2fs-dev` package that provides `ext2fs/ext2_fs.h`, required by tarsnap, not to be confused with `linux/ext2_fs.h`!

**The base tools**, all of priority `required` in Debian, hence present on any installation, `locales` excepted, of priority `standard` and therefore missing from a minimal system:

| Package | Provides |
|---|---|
| `coreutils` | `date`, `uname`, `sort`, `chmod`, `cat`, `mktemp`, `mkdir`, `rm`, `mv`, `join`, `sleep`, `stdbuf` |
| `grep`, `sed`, `findutils`, `diffutils` | `grep`, `sed`, `find`, `cmp` |
| `mawk` | `awk`, for `tarsnap-stats.sh` |
| `util-linux`, `bsdutils` | `flock`, `logger` |
| `libc-bin` | `locale` |
| `dpkg`, `apt` | `dpkg`, `apt` and `apt-mark`, for the package inventory |
| `locales` | the generation of `en_US.UTF-8` |

```sh
apt install coreutils grep sed findutils diffutils mawk util-linux bsdutils libc-bin dpkg apt locales
```

`stdbuf` is optional: without it, the progress lines of `tarsnap-diff.sh` and `tarsnap-stats.sh` lose their live counter.

**The `en_US.UTF-8` locale must be generated**, for predictable output from tarsnap, `apt` and `date`. The script refuses to start without it:

```sh
dpkg-reconfigure locales
```

`C.UTF-8`, which every Debian provides, is not accepted in its place: the scripts force `en_US.UTF-8`, the locale in which the output of Tarsnap was checked, including the escapes that `tarsnap-diff.sh` undoes in the names of a listing.

### Other systems

The script is not portable as is.
It should run on another "Debian-like" distribution.

If you want to port it, the `dpkg`, `apt` and `apt-mark` inventory is the first thing to replace.  
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
Installed there, it is archived with the rest, settings and hooks included: the shipped `BACKUP_DIRS` covers `/usr/local/sbin`, see [Backup contents](#backup-contents).

The other three scripts are optional extras and do not need to be installed in `/usr/local/sbin/`.  
Git keeps them executable, mode `100755` in the repository: run them straight from the cloned repository, without any `chmod`.  
Only if you fetched them some other way, a raw download for instance, restore the executable bit:

```sh
chmod +x rotation-check.sh tarsnap-diff.sh tarsnap-stats.sh
```

- `rotation-check.sh` simulates your retention configuration, or replays it against your real data.
- `tarsnap-diff.sh` compares a snapshot with the current state of the system.

Both fetch their configuration from `tarsnap-backup.sh`, at the expected paths:

- First `/usr/local/sbin/tarsnap-backup.sh`
- Then, failing that, a `tarsnap-backup.sh` next to them, in their own directory.

An installed copy that exists but cannot be read stops them, rather than leaving them to read the copy of the repository, whose values may well differ from those of production: run them as root, like the backup, or name the file with `-f`.

- `tarsnap-stats.sh`, for its part, reads none of this: it relies on your `tarsnap.conf` and has no configuration of its own.

Then edit the configuration block at the top of the file (next section), check the syntax, and do a trial run with `--dry-run`, which prevents any snapshot from being created:

```sh
sh -n /usr/local/sbin/tarsnap-backup.sh
/usr/local/sbin/tarsnap-backup.sh --dry-run --verbose
```

A dry run does not check everything, and says so at the end: see [Usage](#usage).

Once satisfied, schedule it in `/etc/crontab`, or in a file of `/etc/cron.d`: both lie under `/etc`, so that the schedule is archived with the rest.

```
02 00   * * *   root /usr/local/sbin/tarsnap-backup.sh
```

Root's crontab, edited with `crontab -e`, would do just as well, with the same line minus the user field. But it is kept under `/var/spool/cron/crontabs`, which the shipped `BACKUP_DIRS` does not cover: add that directory to it, or a restore will not bring the schedule back.

Without `--verbose`, the script is silent in normal operation, even when `tarsnap.conf` sets `print-stats`, `totals` or `progress-bytes`: it overrides them for the run, since their output on standard error would make a `cron` mail every night.  
Only errors and warnings go to standard error, hence into the `cron` mail, or elsewhere depending on your setup.

A real run that creates its archive and ends with status 0 or 2 also writes the name of that archive to `LAST_SUCCESS`, `/root/tarsnap-backup.last-success` by default. A second line, at noon, checks that this file was rewritten during the last 25 hours, and writes a warning otherwise, hence a `cron` mail as well:

```
00 12   * * *   root test -n "$(find /root/tarsnap-backup.last-success -mmin -1500 2>/dev/null)" || echo "tarsnap-backup: no successful run for 25 hours"
```

### Updating

A new version copied over the installed one brings back the shipped configuration block, and with it the default retention: its next run would purge accordingly, and the purge circuit breaker only stops it past `MAX_PURGE` archives.  
Carry your settings and your hooks over into the new version first, then try it before installing it:

```sh
cp tarsnap-backup.sh /root/tarsnap-backup.sh.new
diff -u /usr/local/sbin/tarsnap-backup.sh /root/tarsnap-backup.sh.new
```

The diff shows your settings and your hooks, to report into `/root/tarsnap-backup.sh.new`, and what the new version adds to the block: a new variable keeps its shipped value until you set it. Then:

```sh
sh -n /root/tarsnap-backup.sh.new
sh /root/tarsnap-backup.sh.new --dry-run --verbose
cp /root/tarsnap-backup.sh.new /usr/local/sbin/tarsnap-backup.sh
```

The last `cp` keeps the mode and the owner of the installed file.

## Configuration

Everything is set in the block at the top of the file, between `CONFIGURATION` and `END OF CONFIGURATION`.

`rotation-check.sh` and `tarsnap-diff.sh` read part of this block as plain text, without ever running the file: the five retention values, `MAX_PURGE`, `TARSNAP_KEY`, `TARSNAP_PASSPHRASE`, `BACKUP_DIRS` and `BACKUP_EXCLUDE`.  
Keep the shipped layout for these: one line each, starting with the name and defined only once, which both tools check, integers without quotes, strings between double quotes with none inside, and no `$VARIABLE`.  
Renaming one of them breaks the tool that reads it: see [HACKING.md](HACKING.md#configuration-read-by-the-companion-tools).

### Binary paths

`TARSNAP_BIN`, `DATE_BIN`, `UNAME_BIN`, `LOCALE_BIN`, `GREP_BIN`, `SED_BIN`, `SORT_BIN`, `DPKG_BIN`, `APT_BIN`, `APT_MARK_BIN`, `FLOCK_BIN`, `CHMOD_BIN`, `LOGGER_BIN`.

The binary paths are hardcoded so as not to depend on the caller's `PATH`, be it `cron`, `systemd` or a misconfigured `sudo`.  
The shipped values are those of Debian with `usrmerge`, hence everything under `/usr/bin`. At startup, the script checks that each of them is executable, and refuses to run otherwise.

### Tarsnap

`TARSNAP_KEY`: the path of the Tarsnap key, which must not contain whitespace. Leave the variable empty to rely on the `keyfile` declared in `tarsnap.conf`: the script then asks Tarsnap which key that is, through `tarsnap --dump-config`, and checks it in the same way, except in the cases listed under [Known limitations](#known-limitations).  
The key that `tarsnap-keygen` generates holds every permission, which is what the script needs: the rotation deletes, and deleting an archive requires reading it, `-d` implying `-r` in [tarsnap-keymgmt](https://www.tarsnap.com/man-tarsnap-keymgmt.1.html). The flip side: root on this machine can delete every archive of the key, see [Known limitations](#known-limitations).

**One key per machine.** Tarsnap keeps in the cache directory the sequence number of the last transaction, which the server checks at every creation and deletion. Two machines sharing a key each have their own cache directory: whichever did not write last fails at every real run, on `Sequence number mismatch: Run --fsck`, while its dry runs, which write nothing, still pass. And the lock of the script, local to each machine, does not keep them from writing at the same time, which Tarsnap forbids with a single key.

**Keep a copy of the key off the machine**, and of its passphrase if it has one: without the key the archives [cannot be read back](https://www.tarsnap.com/faq.html#lost-key-file-read-data), and the copy in `/root` is itself only archived encrypted with that very key.

`TARSNAP_PASSPHRASE`: how Tarsnap obtains the passphrase of a protected key. It requires Tarsnap 1.0.40 or later. It is passed on as `--passphrase` to the creation, the listing and the purge, and appears in the commands printed by `--orphans` and `--dry-run`. Leave it empty for the default behaviour, a prompt on the terminal, which `cron` does not have.

| Value | The passphrase is read from |
|---|---|
| empty, or `dev:tty-stdin` | `/dev/tty`, otherwise standard input |
| `dev:tty-once` | `/dev/tty` only |
| `dev:stdin-once` | standard input only |
| `env:NAME` | the environment variable `NAME` |
| `file:PATH` | the file `PATH`, a single line |

Only `env:` and `file:` work without a terminal, hence under `cron`, and `file:` is the one to prefer there.  
Keep the file in mode 0600. For `env:`, pick a variable name of your own rather than one of the script's variables, and never define it in a crontab: `cron` writes the environment of the job, the variables of the crontab included, into the `X-Cron-Env` headers of every mail it sends, and the passphrase along with them. If `env:` is required, export the variable from a wrapper in mode 0700 that ends with `exec /usr/local/sbin/tarsnap-backup.sh "$@"`.  
On the command line, this setting takes precedence over a `passphrase` line of `tarsnap.conf`, which Tarsnap then silently ignores. Whitespace is not allowed.

Before `prebackup`, the script refuses whitespace in `TARSNAP_KEY` or `TARSNAP_PASSPHRASE`, an unknown method and an invalid variable name, without ever repeating the value of `TARSNAP_PASSPHRASE`, which could be the passphrase itself, written there by mistake. Then, for a protected key, it checks that the passphrase can actually be obtained:

- default and `dev:tty-stdin`: `/dev/tty` can be opened, or standard input is a terminal;
- `dev:tty-once`: `/dev/tty` can be opened;
- `dev:stdin-once`: standard input is a terminal;
- `env:`: the variable is set and not empty;
- `file:`: the file is readable, is not a directory, and holds a single line of at most 2047 bytes, line feed included, that is neither empty nor starts with a CR or a NUL: Tarsnap would read an empty passphrase. A file that is not a regular one, such as a named pipe, is only checked for readability, so as not to consume it.

Nothing is checked for a key known to be plain: Tarsnap only reads the passphrase to decrypt a key.  
When the check fails, the run stops with `ERROR: passphrase-protected key, <reason>: <key>`, followed by `(from tarsnap.conf)` when the key comes from there. In `--verbose` mode, the script reports the key read from `tarsnap.conf`, and for a protected key, how its passphrase will be obtained.

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

- `BACKUP_DIRS`: directories to include, space-separated absolute paths, `/root /boot /etc /usr/local/sbin` as shipped.
- `BACKUP_EXCLUDE`: exclusion patterns, space-separated.

Both lists are split on spaces: a path containing whitespace cannot appear in either of them.

`/usr/local/sbin` is there for this very script: restored with the rest, it brings back your retention values and your hooks, which a copy reinstalled from the repository would not have.

Each directory loses its trailing slashes, and must then be its canonical path: a relative path, `//`, a `.` or `..` component and a symbolic link are refused, before `prebackup`. Under another name, an absolute exclusion would no longer match, and a restore by the canonical path would find nothing; through a symbolic link, Tarsnap would archive the link alone, and nothing of what it points to. A directory that does not exist is not refused: Tarsnap reports it, and the run then ends with exit status 2.

Two forms of exclusion are accepted, both passed as is to Tarsnap, which matches them against the whole path of each entry on disk, leading `/` included:

1. An absolute path, for example `/var/www/html/APOD`: anchored at the root, it excludes this path only, and everything below it.
2. A glob pattern, for example `*/tmp/*`. A pattern that starts with `*` is matched against the whole path as well, any other one after each `/` of the path, hence at every level: `cache` alone would exclude every entry named `cache`, wherever it lies.

For an absolute path, the script also passes a second pattern for the contents, as a safety, Tarsnap covering them already. Trailing slashes are removed, and `/` alone is refused: it would empty the archive without a word. The details, sources of Tarsnap included, are in [HACKING.md](HACKING.md#exclusion-matching-in-tarsnap).

### Retention

`DAILY`, `WEEKLY`, `MONTHLY`, `DOW` and `DOM`: see [the retention scheme](#the-retention-scheme) above.

`DOW` is the first day of the weeks, from 0 for Sunday to 6 for Saturday, as `date +%w` counts them: the 7 that `cron` accepts for Sunday is refused. `DOM` is the first day of the months, from 1 to 31, 1 by default.  
The weekly and monthly tiers keep the first archive of each week and of each month: when the night of `DOW` or `DOM` is missed, the next archive of the period stands in for it. With `DOM` at 29, 30 or 31, the short months simply start a few days later: with `DOM=31`, the month named February 2026 runs from 3 to 30 March.

Setting `WEEKLY` or `MONTHLY` to 0 disables the corresponding tier: the diagnostic script `rotation-check.sh` will warn you about it.

Each value is a decimal integer of at most five digits, without a leading zero, which the shell would read as octal, and `DAILY` is at least 1, so that the archive of the run never falls into its own purge. The script checks them at every start, in every mode and before `prebackup`, and names a faulty variable without repeating its value.

`MAX_PURGE` is the purge circuit breaker: the most archives a single run may delete, 7 by default, from 1 to 99999 under the same rules.  
Past it, a real run deletes nothing at all, keeps the archive it has just created, and stops with an error, hence a `cron` mail. Review the purge with `--dry-run --verbose`, then rerun once with `-F`, or `--force-purge`, which lifts the limit for that run only and has no equivalent in the configuration block.  
In steady state, a run deletes one or two archives at most. 7 lets a week of missed nights through, and stops a clock that jumped more than about a week ahead, retention values cut by mistake, or a reinstalled script whose retention went back to the defaults.

### Miscellaneous

`LOCK_FILE`: run lock, `/run/tarsnap-backup.lock` by default, protected twice: `/run`, mode 755 and owned by root, keeps the other users from creating or replacing the file, and the file itself is created in mode 0600, so that they cannot even open it, an open descriptor, read-only or not, being all `flock` needs to hold the lock.  
Neither `/tmp` nor `/run/lock`, which are mode 1777: any local user could create the file there first, and block your backups indefinitely!!!  
A lock left in mode 0644 by an earlier version is brought back to 0600 once held. That does not revoke a descriptor that another user already holds: reboot, `/run` being a tmpfs, or delete the file while no backup is running.

The script sets `umask 077` before creating anything: the lock, the inventories and the dumps of your hooks are private to root.

`PKG_SELECTIONS`, `PKG_LIST` and `PKG_MANUAL`: the three inventory files written by `prebackup`, the selections of `dpkg`, the list of `apt`, and the packages installed on purpose, as `apt-mark showmanual` gives them, the list to hand back to `apt` to rebuild a system.  
Put them in a directory covered by `BACKUP_DIRS`, otherwise they will not make it into the archive.

`LAST_SUCCESS`: the file into which a real run writes the name of its archive when it ends with status 0 or 2, `/root/tarsnap-backup.last-success` by default. Its age tells that the backups have stopped: see the check given under [Installation](#installation).

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

The error you get is the one printed by the failing command itself.  
Before adding a command or a script to one of these functions, check that it runs cleanly: a `--dry-run` that leaves nothing in the `cron` mail, or a run with `--verbose`.

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
The faster `--dry-run-metadata` of Tarsnap 1.0.41 is deliberately not used: see [HACKING.md](HACKING.md#the---dry-run-metadata-bug).

**Note that the script's `-d` means "delete nothing", the exact opposite of Tarsnap's `-d`: `-n` is accepted as a synonym and remains the less ambiguous form.**

`-v`, `--verbose`: details the decision made for each archive, and passes `-v` to Tarsnap.

`-s NAME`, `--snapshot-name NAME`: creates an archive suffixed with `NAME`, then exits without rotating.  
The suffix takes it out of the pattern tested by the purge, so it becomes permanently untouchable by the script.  
**This is what to use before going into production, for example.**

The allowed characters are `A-Z`, `a-z`, `0-9`, `_` and `-`. The `--snapshot-name=NAME` form is also accepted.

`-o`, `--orphans`: lists the archives beyond the reach of the rotation, then exits. See the next section.

`-h`, `--help`: displays the help.

Long options also accept a single leading dash: `-dry-run` is read as `--dry-run`.

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
Their names do not match the pattern of the rotation archives, so the purge excludes them outright: snapshots taken with `-s`, archives made by hand, archives of another machine sharing the same key, archives dating from a previous hostname.

This covers any snapshot created with the Tarsnap key under another name: the purge touches **ONLY** what EXACTLY matches the pattern **`hostname-YYYY-MM-DD_HH-MM-SS`**

**- Partial archives:**  
Suffixed `.part`, they are what is left of an interrupted run: an archive truncated on purpose, by `^Q`, `SIGQUIT` or `--maxbw`, or the last checkpoint of a run that died, which Tarsnap recovers at the next creation or deletion.

They count for deduplication and may contain data found nowhere else.  
The script already reports them on standard error at every rotation. The `--orphans` option gathers them so that you can decide with a cool head.

For each family, the matching delete command is displayed, ready to be reviewed and then pasted.  
It will never be run by the script:

```
Archives beyond the reach of the rotation, hostname "foo".

--- Orphans: name outside the pattern, never purged ---
  foo-2026-01-10_03-00-00_before-prod
  old-manual-backup
  bar-2024-02-01_02-00-00

  Delete command, review before pasting:
  /usr/bin/tarsnap --keyfile /root/tarsnap.key -d -f foo-2026-01-10_03-00-00_before-prod -f old-manual-backup -f bar-2024-02-01_02-00-00

--- Partials: truncated, or checkpoint recovered ---
  foo-2026-10-20_00-02-01.part

  Delete command, review before pasting:
  /usr/bin/tarsnap --keyfile /root/tarsnap.key -d -f foo-2026-10-20_00-02-01.part
```

With `TARSNAP_PASSPHRASE` set, these commands carry the same `--passphrase` option.

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

The output starts with where the configuration comes from and the three ranges, followed by the counters shown [above](#what-it-looks-like-in-practice):

```
tarsnap-backup: rotation consistency check
------------------------------------------
configuration read from /usr/local/sbin/tarsnap-backup.sh

daily      DAILY=90   all              from     0 to    90 d
weekly     WEEKLY=12  DOW=1            from    90 to   174 d
monthly    MONTHLY=48 DOM=1            from   174 to  1635 d
```

In replay mode, the archives are sorted by name, hence by host and then by date, and each one gets its verdict:

```
Replay against the real list, hostname "foo":

  foo-2026-01-10_03-00-00_before-prod outside the pattern, untouchable
  foo-2026-03-01_00-02-01             KEPT  (grandfather, monthly)
  foo-2026-03-02_00-02-01             DELETED
  foo-2026-06-01_00-02-02             KEPT  (father, weekly)
  foo-2026-10-20_00-02-01.part        PARTIAL, left in place
  foo-2026-10-21_00-02-01             KEPT  (son, daily)
```

The options:

| Option | Effect |
|---|---|
| `-D days` | simulation horizon, 1825 days by default |
| `-f script` | path of the `tarsnap-backup.sh` to read |
| `-d DAILY` | overrides the daily window, in days |
| `-w WEEKLY` | overrides the weekly window, in weeks |
| `-m MONTHLY` | overrides the monthly window, in months |
| `-o DOW` | overrides the day of the week kept, 0 = Sunday |
| `-M DOM` | overrides the day of the month kept |
| `-l file` | replays the decision against a list of archives, `-` for standard input |
| `-h` | displays the help |

## Comparing a snapshot with the system

The repository also includes the `tarsnap-diff.sh` script, which compares a Tarsnap snapshot with the current state of the machine and tells you what has changed since.

It sticks to the scope actually backed up: `BACKUP_DIRS`, `BACKUP_EXCLUDE`, `TARSNAP_KEY` and `TARSNAP_PASSPHRASE` are read from `tarsnap-backup.sh`, with the same search order as `rotation-check.sh` and the same precaution: the file is never sourced.  
The two scripts go together: a `tarsnap-backup.sh` from before `TARSNAP_PASSPHRASE` makes `tarsnap-diff.sh` stop with `variable TARSNAP_PASSPHRASE not found`.

Its own configuration block, at the top of the file, only holds the binary paths, `LOG_DIR` and the installed path of `tarsnap-backup.sh`.

No archive is touched.  
Only `-tv` and `-x` are used, both read-only on the Tarsnap side: *"Extracting or listing archives may be performed in parallel with any other operation"*. With `TARSNAP_KEY` empty, a local `tarsnap --dump-config` comes first, to find the key.  
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
The file is downloaded, then compared byte by byte: this is what eliminates the false `*` of a file that was merely touched by a `touch`, a `sed -i` that changes nothing, a restore, and so on.

All the files to download are fetched in **a single** Tarsnap invocation, rather than one per file.

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
The details are therefore written to a file, `$LOG_DIR/<script name>-<snapshot>.log`, i.e. `/var/log/tarsnap-diff.sh-<snapshot>.log` by default, and only the numeric summary is displayed:

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

The log carries the same figures at the top, in a header whose lines start with `#`: 11 lines, or 13 when neither `-i` nor `-m` was requested, which adds a note on the indicative counters. `grep '^#'` extracts it whatever the mode:

```
root@foo:~/tarsnap-tools# grep '^#' /var/log/tarsnap-diff.sh-foo-2026-08-20_00-02-02.log
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

The log is created in mode 0600, under a random name next to its final path, then renamed onto it, and so is the working file of the header: a symbolic link planted beforehand under the name of the log, in `/tmp` for instance, is replaced rather than followed.  
`-l` must name a file: a directory is refused with `log path is a directory`.

### Progress display

When standard error is a terminal, a progress line counts the entries received while the archive is listed, then a spinner turns if files have to be downloaded.  
Without `stdbuf`, the listing gets the plain spinner instead of the counter. Nothing is ever drawn over a passphrase prompt, and `TARSNAP_SPINNER=0` disables the whole display.

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

**GNU userland, like the rest of the suite:** `find -printf` and the `%T` extension of its formats.

**The comparison is about content, not metadata:** a file whose permissions or owner alone have changed comes out as `=`.

**Passphrase-protected key:** the script takes `TARSNAP_PASSPHRASE` from `tarsnap-backup.sh`, passes it to the listing and to the download, and applies the same checks before opening the log: a passphrase that cannot be obtained stops it at once, and the previous log of the same snapshot is kept.  
With `env:` or `file:`, nothing is asked. With the default method or a `dev:` one, Tarsnap asks on the terminal, once for the listing and once more if files have to be downloaded: the download then runs without the progress spinner, leaving the messages of Tarsnap on the terminal, where the prompt stays visible.  
If `TARSNAP_KEY` is empty, the key of `tarsnap.conf` is read through `tarsnap --dump-config`, as in `tarsnap-backup.sh`. When it stays unknown, the script plays it safe in the same way, unless the method is `env:` or `file:`.

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
- **`flock` lock on descriptor 9.** Two runs never overlap, as the Tarsnap manual requires for a given key, and the kernel releases the lock even after a `kill -9` or a power failure: no stale lock file to clean up.
- **Batch purge in a single call.** All the archives to delete go to one `tarsnap -d`, which noticeably speeds up the purge.
- **Strict naming pattern as a safeguard.** Anything that does not exactly match the pattern is never deleted.

The reasons behind them, the other technical choices, the validation procedure and the ShellCheck directives are in [HACKING.md](HACKING.md).

## Known limitations

**The rotation is anchored on `uname -n`:** renaming the machine, or switching from the short name to the fully qualified name, takes all the earlier archives out of the tested pattern.  
They become immortal and will have to be purged by hand: `--orphans` will list them for you.  
If you are planning a rename, clean up first, or accept that the history will be kept.

**The script is specific to Debian-like distributions:** `dpkg` and `apt` are among the mandatory binaries, and the `date` calls rely on the GNU `-d` and `%-d` extensions.  
Elsewhere, it will refuse to start until the configuration block and the package inventory have been adapted.

**Tarsnap exit code 2 is not singled out:** Tarsnap uses it to report an error that occurred after the server-side state had already been modified.  
`set -e` treats it like any other error.

**Passphrase-protected key:** Tarsnap reads the key again on every invocation, and therefore needs the passphrase again, up to three times per run: creation, listing, purge.  
With the default method or a `dev:` one, without the terminal that the method needs, under `cron` for example, the script stops before `prebackup`, with an explicit message: use `env:` or `file:` instead, see [Tarsnap](#tarsnap). A standard input that is not a terminal counts as no terminal: piping the passphrase in is not supported, since every invocation would read it again. To run the script through `ssh host command`, add `-t`.

**A `passphrase` line in `tarsnap.conf` is not seen:** the script only reads the key there. A `passphrase` line with `env:` or `file:` would be enough for Tarsnap without a terminal, but the script refuses the protected key all the same: set the method in `TARSNAP_PASSPHRASE` instead, which takes precedence over `tarsnap.conf`.

**The key of `tarsnap.conf` may stay unknown:** with `TARSNAP_KEY` empty, the script cannot tell which key Tarsnap will use when `tarsnap --dump-config` exits with a non-zero status (Tarsnap older than 1.0.40, invalid configuration), shows no `keyfile` line, or gives a path that starts with `~` or contains a blank. Tarsnap expands `~` from the password database, which the script does not read.  
Only an `env:` or `file:` method is then checked, and a protected key asked on the terminal will only fail once `prebackup` has run. An unreadable key is treated in the same way, and left to Tarsnap, which names it in its own error message.

**Tarsnap older than 1.0.40:** it knows neither `--passphrase` nor `--dump-config`, and the script does not check the version: with `TARSNAP_PASSPHRASE` set, a backup fails as soon as Tarsnap receives `--passphrase`, at the creation of the archive, after `prebackup` has run.

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

`tarsnap-stats.sh`, which comes from [its own repository](https://github.com/deuza/tarsnap-stats), is released under the same license.

<p align="center">With ❤️ by <a href="https://github.com/deuza">DeuZa</a></p>
