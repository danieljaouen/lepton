## DESCRIPTION

Write the STRINGs to standard output, separated by single spaces and
followed by a newline.

Options are recognised only before the first STRING.

## OPTIONS

- `-n`: do not print the trailing newline.
- `-e`: interpret backslash escapes: `\n` (newline), `\t` (tab), `\r`
  (carriage return), `\a` (bell), `\e` and `\033` (escape), `\\`
  (backslash).
- `-E`: do not interpret escapes (the default).

## EXAMPLES

    echo hello world
    echo -n "no newline"
    echo -e "one\ntwo"

## SEE ALSO

printf(1)
