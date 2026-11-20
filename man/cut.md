## DESCRIPTION

Print selected parts of each line of each FILE (or of standard input):
fields with `-f`, or characters with `-c`.

A LIST is a comma-separated list of numbers and ranges, counting from 1:
`N`, `N-M`, `N-` (to the end of the line) or `-M` (from the start).

## OPTIONS

- `-f LIST`: print these fields.
- `-d DELIM`: fields are separated by DELIM (a tab by default).
- `-c LIST`: print these characters.
- `-s`: with `-f`, skip lines that contain no delimiter.

## EXAMPLES

    cut -d : -f 1,7 /etc/passwd
    echo hello | cut -c 2-4

## SEE ALSO

awk(1), sort(1), tr(1)
