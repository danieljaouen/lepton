## DESCRIPTION

Write the lines of all FILEs (or of standard input) sorted. By default
lines are compared as text, character by character.

## OPTIONS

- `-n`: compare numerically (by the number at the start of the key).
  Lines without a number sort first.
- `-r`: reverse the order.
- `-u`: print only one of each run of equal lines (equal keys).
- `-f`: ignore case.
- `-k N`: sort by the Nth field (fields are separated by white space,
  or by SEP with `-t`). `-k N,M` is accepted; only N is used.
- `-t SEP`: fields are separated by SEP.

## EXAMPLES

    sort names.txt
    du -s * | sort -rn | head
    sort -t : -k 3 -n /etc/passwd

## SEE ALSO

uniq(1), cut(1), tac(1)
