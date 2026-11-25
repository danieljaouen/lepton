## DESCRIPTION

Copy SOURCE to DEST, or several SOURCEs into the directory DEST. When
DEST is an existing directory, each SOURCE is copied into it under its
own name; otherwise DEST is the name of the copy (and only one SOURCE is
allowed).

A link to a file copies the file; with `-r`, links inside folders are
copied as links. Files are copied in 8 MiB pieces and written out every
64 MiB, so big files (many gigabytes) copy without stalling the system,
and Ctrl+C stops a copy part way. The space is checked first: a copy
that doesn't fit where it goes, or that would leave the machine less
than 512 MiB of memory on `/` (which is in memory), fails with "No space
left on device" before anything is written.

## OPTIONS

- `-r`, `-R`, `-a`: copy directories recursively.
- `-v`: print each copy as `'SOURCE' -> 'DEST'`.
- `-p`, `-f`: accepted for compatibility.

## EXIT STATUS

0 if everything was copied, 1 otherwise.

## EXAMPLES

    cp notes.txt notes.txt.bak
    cp -r ~/.config/le /tmp/le-backup
    cp *.png ~/Pictures/

## SEE ALSO

mv(1), ln(1), rm(1), rsync(1), tar(1), https://trylepton.app/docs/archives.html
