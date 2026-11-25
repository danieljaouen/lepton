## DESCRIPTION

Read items from standard input and run CMD with them added as
arguments. CMD defaults to `echo`. All items are passed to one run of
CMD unless `-n` limits the number.

Items are separated by blanks and newlines, as GNU xargs does: quotes
(`'my file'`, `"my file"`) or a backslash (`my\ file`) keep blanks in
one. For names that may hold anything, use `find -print0` and `xargs -0`.

## OPTIONS

- `-0`: items end in NUL bytes (as `find -print0` writes them): blanks,
  quotes and newlines in them are kept as they are.
- `-n N`: pass at most N items to each run of CMD.
- `-I STRING`: each input line is one item, and CMD runs once per item,
  with STRING in its arguments replaced by the item.

## EXIT STATUS

The highest exit status of the runs of CMD.

## EXAMPLES

    find . -name '*.tmp' -print0 | xargs -0 rm
    ls *.txt | xargs -n 1 wc -l
    cat hosts.txt | xargs -I @ ping -c 1 @

## SEE ALSO

find(1), echo(1)
