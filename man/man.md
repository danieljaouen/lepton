## DESCRIPTION

Show the manual page for a command: what it does, its options, and
examples. On a terminal the page is shown in the pager (see `less`:
Space for the next screen, `/` to search, `q` to quit); otherwise it is
printed as plain text.

Every command that comes with Lepton has a page, and so does each of the
shell's builtin commands, such as `cd` and `export`. The page `builtins`
describes them all together.

A section number (`man 1 ls`) is accepted and ignored: all pages are in
section 1.

## OPTIONS

- `-k KEYWORD...`: list the pages whose name or summary contains a
  KEYWORD (`apropos`, which can search the pages' text too).
- `-f NAME...`: print the one-line summary of each NAME (`whatis`).

## ENVIRONMENT

- `MANWIDTH`: the width to lay the page out at. By default it is the
  terminal's width, at most 80 columns.
- `NO_COLOR`: when set, show the page without bold and underlining.

## EXIT STATUS

0 on success, 16 if there is no such page.

## EXAMPLES

    man ls
    man -k disk
    man cd

## SEE ALSO

apropos(1), whatis(1), help(1), less(1), builtins(1)
