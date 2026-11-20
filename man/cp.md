## DESCRIPTION

Copy SOURCE to DEST, or several SOURCEs into the directory DEST. When
DEST is an existing directory, each SOURCE is copied into it under its
own name; otherwise DEST is the name of the copy (and only one SOURCE is
allowed).

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

mv(1), ln(1), rm(1), rsync(1)
