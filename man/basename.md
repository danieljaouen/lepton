## DESCRIPTION

Print NAME with any leading directory components removed. If SUFFIX is
given and NAME ends with it, remove that too.

## EXAMPLES

    basename /home/alice/notes.txt          # notes.txt
    basename /home/alice/notes.txt .txt     # notes

## SEE ALSO

dirname(1), realpath(1)
