## DESCRIPTION

Rename SOURCE to DEST, or move several SOURCEs into the directory DEST.
When DEST is an existing directory, each SOURCE moves into it under its
own name. Moving between file systems (for example from a USB drive to
your home directory) copies and then removes the source.

## OPTIONS

- `-v`: print each move as `'SOURCE' -> 'DEST'`.
- `-f`: accepted for compatibility (`mv` never prompts).

## EXIT STATUS

0 if everything was moved, 1 otherwise.

## EXAMPLES

    mv draft.md post.md
    mv *.jpg ~/Pictures/

## SEE ALSO

cp(1), rm(1)
