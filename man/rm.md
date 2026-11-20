## DESCRIPTION

Remove each FILE. Directories are removed only with `-r`. A symbolic
link is removed itself, never what it points to. There is no trash:
removed files are gone.

`rm` refuses to remove `/`.

## OPTIONS

- `-r`, `-R`: remove directories and their contents, recursively.
- `-f`: ignore FILEs that do not exist.
- `-v`: print the name of each FILE removed.
- `-d`: accepted for compatibility; has no effect.

## EXIT STATUS

0 if every FILE was removed, 1 otherwise.

## EXAMPLES

    rm notes.txt.bak
    rm -rf build/

## SEE ALSO

rmdir(1), mv(1)
