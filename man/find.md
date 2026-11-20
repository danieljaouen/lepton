## DESCRIPTION

Walk the directory tree under each PATH (the current directory by
default) and print the path of every file and directory that matches all
of the tests given. With no tests, everything is printed. Directories
are visited in name order; symbolic links are not followed.

## TESTS

- `-name GLOB`: the file's name (not its directory) matches GLOB, where
  `*` matches anything, `?` one character and `[...]` one of a set.
  Quote GLOB so the shell does not expand it.
- `-iname GLOB`: like `-name`, ignoring case.
- `-type f|d|l`: a regular file, a directory, or a symbolic link.
- `-maxdepth N`: descend at most N levels below PATH.
- `-mindepth N`: do not print anything less than N levels below PATH.

Other tests and actions of GNU or BSD `find` are not supported and are
ignored.

## EXAMPLES

    find . -name '*.ex'
    find ~ -maxdepth 2 -type d
    find /persist -iname '*.PNG' | xargs ls -l

## SEE ALSO

ls(1), tree(1), grep(1), xargs(1)
