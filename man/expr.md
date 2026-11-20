## DESCRIPTION

Print the result of an integer operation: `+`, `-`, `*` (quote it so
the shell does not expand it), `/` (integer division, rounding toward
zero) or `%` (remainder).

The shell's own arithmetic, `$(( ... ))`, is usually more convenient.

## EXIT STATUS

0 if the result is not zero, 1 if it is zero, 2 for a syntax error.

## EXAMPLES

    expr 6 '*' 7
    n=$(expr $n + 1)

## SEE ALSO

test(1), seq(1), lsh(1)
