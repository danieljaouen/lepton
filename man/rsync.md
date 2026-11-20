## DESCRIPTION

Copy files and directories to DEST, sending only what changed. A file
that is already at DEST with the same size and modification time is
skipped; a changed file is updated by sending just its differences, so
syncing a big directory again is quick.

SOURCE and DEST are local paths or, for another machine, `[USER@]HOST:PATH`
reached over SSH (with your keys, as `ssh` uses them). The other machine
needs `rsync`: Linux and macOS have it, and so does Lepton, so a Mac can
sync to Lepton too, through its SSH server (`sshd`).

A trailing `/` on a source directory means its contents: `rsync -a
src/ dst` makes `dst` a copy of `src`, while `rsync -a src dst` makes
`dst/src`.

## OPTIONS

- `-a`, `--archive`: the usual choice: `-rlpt` (recursive, links,
  permissions, times). Its `-o`, `-g` and `-D` are accepted, but owners,
  groups and devices are not copied.
- `-v`, `--verbose`: list the files and directories transferred, then the
  bytes sent and received.
- `-r`, `--recursive`: copy directories and everything in them.
- `-l`, `--links`: copy symbolic links as links (without it they are
  skipped).
- `-p`, `--perms`: copy permissions.
- `-t`, `--times`: copy modification times (needed for the quick check
  to skip unchanged files next time).
- `-d`, `--dirs`: copy directories named, without their contents.
- `-n`, `--dry-run`: show what would be done, but change nothing.
- `-c`, `--checksum`: compare files by their contents, not size and time.
- `-u`, `--update`: skip files that are newer at DEST.
- `-I`, `--ignore-times`: send files even when size and time match.
- `--size-only`: skip files whose size matches.
- `-W`, `--whole-file`: send whole files, not differences.
- `--delete`: delete files at DEST that are not in SOURCE (in the
  directories being copied). Excluded files are kept.
- `--exclude PATTERN`: leave out files matching PATTERN: `*`, `?` and
  `[...]` match within a name and `**` across directories; a pattern
  without `/` matches the name anywhere, a leading `/` anchors it to the
  top of the transfer, and a trailing `/` matches only directories. May
  be repeated.
- `-z`, `--compress`: accepted. Lepton compresses when another machine's
  rsync asks it to; its own transfers are not compressed.
- `-e COMMAND`, `--rsh COMMAND`: the ssh command line for another
  machine, with the ssh options Lepton's `ssh` takes, as in `-e 'ssh -p
  2222 -i ~/.ssh/work_ed25519'`.
- `--rsync-path PATH`: the rsync to run on the other machine.
- `-h`, `-P`, `--progress`, `--stats`, `-q` and the like are accepted and
  ignored.

`-H` (hard links) and `-R` (relative paths) are not supported.

## COMPATIBILITY

Lepton's rsync speaks version 27 of rsync's protocol, which rsync 3.x
and macOS's own rsync (openrsync) both accept, in both directions.
Daemon mode (`rsync://`) is not supported.

## EXIT STATUS

0 on success, 1 for a usage error, 2 if the other side's protocol is too
old, 12 if the connection broke, 23 if some files were not transferred,
255 if SSH could not connect.

## EXAMPLES

    rsync -av ~/notes/ /media/USB/notes/          # back up to a USB drive
    rsync -av --delete src/ me@server:src/       # mirror to another machine
    rsync -avz me@mac:Projects/app/ ~/app/        # fetch from a Mac
    rsync -avn --delete src/ backup/              # see what would change

From a Mac, to Lepton (with `sshd` enabled):

    rsync -avz ~/Projects/app/ alice@lepton.local:app/

## SEE ALSO

cp(1), ssh(1), sshd(1), https://trylepton.app/docs/rsync.html
