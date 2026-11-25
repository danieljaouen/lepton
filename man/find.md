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
- `-user NAME|UID`, `-group NAME|GID`: owned by that user or group.
- `-maxdepth N`: descend at most N levels below PATH.
- `-mindepth N`: do not print anything less than N levels below PATH.
- `-xdev` (or `-mount`): don't descend into other file systems.
- `-print0`: end each path with a NUL byte rather than a newline, for
  `xargs -0`: names with spaces (or newlines) stay whole.

Other tests and actions of GNU or BSD `find` are not supported: `find`
says so and exits with status 1, rather than printing everything.

## EXAMPLES

    find . -name '*.ex'
    find ~ -maxdepth 2 -type d
    find ~ -user root              # anything in your home that isn't yours
    find . -name '*.log' -print0 | xargs -0 rm    # any names, spaces and all
    find /persist -iname '*.PNG' | xargs ls -l

## SEE ALSO

ls(1), tree(1), grep(1), xargs(1)
