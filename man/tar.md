## DESCRIPTION

Make (`-c`), list (`-t`) or unpack (`-x`) a tar archive, as GNU tar.
Archives may be compressed with gzip (`.tar.gz`, `.tgz`), bzip2
(`.tar.bz2`), xz (`.tar.xz`) or zstd (`.tar.zst`): `-z`, `-j`, `-J` and
`--zstd` (or `-a`, by the name) compress when making one, and reading
recognises the compression by itself. The first argument may leave out
its dash (`tar xzf FILE`).

Members named after the archive are the only ones listed or unpacked
(a folder brings everything in it; `*`, `?` and `[...]` match). When
unpacking, a leading `/` is taken off the names, and members with `..`
in their names are skipped. Long names (pax and GNU), symbolic links,
hard links, permissions and modification times are kept.

gzip is Lepton's own and bzip2 is busybox's, always there. xz and zstd
are the `compressors` app's (about 2 MB; tar offers to install it), but
busybox reads `.tar.xz` without it.

## OPTIONS

- `-c`, `--create`: make an archive of the FILEs (folders with everything in them).
- `-x`, `--extract`: unpack.
- `-t`, `--list`: list the members (with `-v`: as `ls -l`).
- `-f ARCHIVE`, `--file=ARCHIVE`: the archive (`-`: standard input or output, the default).
- `-z`, `--gzip`: compress with gzip.
- `-j`, `--bzip2`: compress with bzip2.
- `-J`, `--xz`: compress with xz.
- `--zstd`: compress with zstd.
- `-a`, `--auto-compress`: compress by the archive's name (`.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tar.xz`, `.txz`, `.tar.zst`, `.tzst`).
- `-C DIR`, `--directory=DIR`: work in DIR (unpack into it; name files from it).
- `-v`, `--verbose`: print each member's name (twice: as `-tv` does).
- `-O`, `--to-stdout`: unpack to standard output.
- `-k`, `--keep-old-files`: don't replace files that exist.
- `--strip-components=N`: leave the first N folders out of the names.
- `--exclude=PATTERN`: leave out files whose name (or base name) matches.
- `-p`, `-o`, `-m`: accepted for compatibility.

## EXAMPLES

    tar czf notes.tgz notes/
    tar tvf notes.tgz
    tar xf release.tar.gz -C ~/src --strip-components=1
    tar caf backup.tar.gz --exclude='*.log' ~/Documents
    tar xf linux-6.18.tar.xz
    tar cJf photos.tar.xz Pictures/
    tar xOf notes.tgz notes/todo.txt

## EXIT STATUS

0 on success. 2 if a file couldn't be read or written, a member wasn't
found, the archive is damaged, or for a usage error.

## SEE ALSO

unzip(1), cp(1), https://trylepton.app/docs/archives.html
