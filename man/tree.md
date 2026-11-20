## DESCRIPTION

Print the contents of DIR (the current directory by default) and its
subdirectories as an indented tree, followed by the number of
directories and files. Hidden entries are left out unless `-a` is
given.

## OPTIONS

- `-a`: include names starting with `.`.
- `-L N`: descend at most N levels.
- `-d`: list directories only.

## EXAMPLES

    tree -L 2 ~/src

## SEE ALSO

ls(1), find(1), du(1)
