## DESCRIPTION

A small subset of `awk` for picking fields out of lines. PROGRAM has the
form

    [/REGEX/] [{ print EXPR, EXPR, ... }]

and is applied to each line of each FILE (or of standard input). Lines
not matching REGEX are skipped; with no action the whole line is
printed. Each EXPR is one of:

- `$0`: the whole line.
- `$1`, `$2`, `$3`: a field (fields are separated by white space, or by
  SEP with `-F`).
- `$NF`: the last field.
- `NR`: the line number.
- `NF`: the number of fields.
- `"text"`: a literal string.

The values are printed separated by spaces. Variables, arithmetic,
`BEGIN`/`END` blocks and functions are not supported.

## OPTIONS

- `-F SEP`: fields are separated by SEP.

## EXAMPLES

    ps | awk '{ print $1, $NF }'
    awk -F : '/bash/ { print $1 }' /etc/passwd

## SEE ALSO

cut(1), sed(1), grep(1)
