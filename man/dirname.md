## DESCRIPTION

Print each NAME with its last component removed: the directory that
contains it. A NAME without a `/` gives `.`.

## EXAMPLES

    dirname /home/alice/notes.txt   # /home/alice
    dirname notes.txt               # .

## SEE ALSO

basename(1), realpath(1)
