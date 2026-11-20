## DESCRIPTION

Print the first 10 lines of each FILE (or of standard input). With more
than one FILE, each is preceded by a `==> FILE <==` header.

## OPTIONS

- `-n N`, `-N`: print the first N lines instead.

## EXAMPLES

    head -n 3 /etc/passwd
    ls -t | head -5

## SEE ALSO

tail(1), cat(1), less(1)
