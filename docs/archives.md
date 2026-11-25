---
title: Archives and big files
order: 9
section: shell
summary: tar and unzip for .tar, .tar.gz and .zip files, and copying big files with cp and mv.
---

# Archives and big files

## tar

`tar` makes, lists and unpacks tar archives, plain (`.tar`) or
compressed with gzip (`.tar.gz`, `.tgz`), as GNU tar does. The first
argument may leave out its dash, as in `tar xzf`:

```sh
tar czf notes.tgz notes/          # make notes.tgz from the folder notes
tar tvf notes.tgz                 # list it, with sizes and dates
tar xf notes.tgz                  # unpack it here (gzip is recognised: -z is optional)
tar xf release.tar.gz -C ~/src    # unpack into ~/src
tar xf release.tar.gz --strip-components=1   # without the top folder
tar caf backup.tar.gz ~/Documents # -a: compressed or not by the name
tar xOf notes.tgz notes/todo.txt  # a member to the screen (-O)
```

Name members after the archive to unpack just those (a folder brings
everything in it; `*` and `?` work too). `--exclude=PATTERN` leaves
files out when making one, `-k` keeps files that are already there.

Archives from elsewhere unpack safely: a leading `/` is taken off the
names, and a member whose name climbs out with `..` is skipped. Long
names, symbolic links and permissions are kept both ways; the files
you unpack are yours. Archives compressed with xz, bzip2 or zstd
(`.tar.xz`, `.tar.bz2`, `.tar.zst`) aren't supported yet: tar says
which it found.

## unzip

`unzip` lists, tests and unpacks `.zip` files, as Info-ZIP's `unzip`:

```sh
unzip photos.zip                  # unpack here
unzip photos.zip -d ~/Pictures    # unpack into a folder
unzip -l photos.zip               # list
unzip -t photos.zip               # check every file's CRC
unzip -p notes.zip todo.txt       # a file to the screen
unzip photos.zip '*.jpg' -x 'thumbs/*'
```

When a file is already there, `unzip` asks (`[y]es, [n]o, [A]ll,
[N]one`); `-o` replaces without asking and `-n` never replaces. `-j`
leaves out the folders, `-q` the messages. Files are read from the
archive as they're unpacked, so a big zip doesn't need to fit in memory.
Stored and deflated files are supported (what nearly every zip holds),
zip64 archives too; encrypted ones aren't.

## Copying big files

`cp` and `mv` (between file systems) copy in 8 MiB pieces, writing each
64 MiB to the disk as they go, so copying files of many gigabytes keeps
the system responsive, and Ctrl+C stops a copy part way.

They check for space first. `/` (and so `/tmp`) is in memory on
Lepton: a copy there that would leave the machine less than 512 MiB of
memory is refused with "No space left on device" rather than filling
memory. Big files belong in your home folder, which is on the disk.

<!-- commands: tar unzip cp mv -->
