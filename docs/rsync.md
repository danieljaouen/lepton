---
title: Syncing files (rsync)
order: 7
summary: rsync to copy and mirror directories locally, to USB drives and between machines over SSH, sending only what changed.
---

# Syncing files: rsync

`rsync` copies files and directories and, run again, sends only what
changed: unchanged files are skipped, and a changed file is patched with
its differences. Use it for backups to a USB drive, for keeping a copy of
a project on a server, or for moving work between your Mac and Lepton.

```sh
rsync -av ~/notes/ /media/USB/notes/        # back up to a USB drive
rsync -av --delete src/ backup/             # mirror: also delete what's gone from src
rsync -avn --delete src/ backup/            # dry run: show what would change
```

`-a` is the usual choice: it copies directories recursively, with
symbolic links, permissions and modification times (which is how the
next run knows what hasn't changed). `-v` lists what was transferred.

A trailing `/` on the source means "its contents": `rsync -a src/ dst`
makes `dst` a copy of `src`, while `rsync -a src dst` makes `dst/src`.

## Another machine

Write the other end as `[user@]host:path`. rsync goes over SSH, with your
keys, as [ssh](ssh.html) does, and runs `rsync` on the other machine:

```sh
rsync -av ~/app/ me@server:app/              # push
rsync -av me@mac.local:Projects/app/ ~/app/  # pull
rsync -av -e 'ssh -p 2222' ~/app/ me@server:app/
```

It speaks rsync's own protocol (version 27), so the other end can be
Linux's rsync, macOS's (openrsync, or Homebrew's rsync 3), or Lepton.

## From your Mac to Lepton

With Lepton's [SSH server](ssh.html#logging-in-to-lepton) enabled, your
Mac's own `rsync` can sync to and from Lepton: Lepton runs its rsync on
its side.

```sh
rsync -avz ~/Projects/app/ alice@192.168.1.23:app/    # Mac -> Lepton
rsync -avz alice@192.168.1.23:notes/ ~/lepton-notes/  # Lepton -> Mac
```

`-z` (compression) works when the Mac asks for it.

## Options

| Option | Meaning |
|---|---|
| `-a` | archive: `-rlpt` (owners, groups and devices are not copied) |
| `-v` | list what was transferred |
| `-n` | dry run: change nothing |
| `--delete` | delete what isn't in the source (excluded files are kept) |
| `--exclude PATTERN` | leave out matching files (`*.log`, `node_modules/`, `/build`) |
| `-c` | compare contents, not size and time |
| `-u` | skip files that are newer at the destination |
| `-e 'ssh ...'` | ssh options for another machine (`-p`, `-i`, `-l`, `-o`) |

`man rsync` has the full list.

## Not supported

Hard links (`-H`), relative paths (`-R`), owners and groups, and rsync's
daemon mode (`rsync://`). Lepton's own transfers are not compressed.

<!-- commands: rsync -->
