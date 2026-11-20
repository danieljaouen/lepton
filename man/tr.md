## DESCRIPTION

Copy standard input to standard output, replacing each character found
in SET1 with the character at the same position in SET2 (the last
character of SET2 is repeated when it is shorter). With `-d`, delete the
characters in SET1 instead.

Sets may contain ranges (`a-z`), the classes `[:lower:]`, `[:upper:]`,
`[:digit:]` and `[:space:]`, and escapes such as `\n` and `\t`.

## OPTIONS

- `-d`: delete the characters in SET1.
- `-s`: after translating, squeeze runs of a repeated character into
  one.

## EXAMPLES

    echo hello | tr a-z A-Z
    tr -d '\r' < dos.txt > unix.txt
    echo "a  b   c" | tr -s ' ' ' '

## SEE ALSO

sed(1), cut(1)
