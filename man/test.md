## DESCRIPTION

Evaluate EXPRESSION and exit with status 0 if it is true, 1 if it is
false. `[ EXPRESSION ]` is the same command; the closing `]` is
required by convention. It is mostly used with `if`, `while`, `&&` and
`||`.

## EXPRESSIONS

- `-e FILE`: FILE exists.
- `-f FILE`: FILE is a regular file.
- `-d FILE`: FILE is a directory.
- `-L FILE`, `-h FILE`: FILE is a symbolic link.
- `-s FILE`: FILE exists and is not empty.
- `-x FILE`: FILE has an execute bit set.
- `-r FILE`, `-w FILE`: FILE exists.
- `-z STRING`: STRING is empty.
- `-n STRING`: STRING is not empty.
- `STRING`: STRING is not empty.
- `S1 = S2`, `S1 == S2`, `S1 != S2`: the strings are equal, or not.
- `N1 -eq N2`: the integers are equal; likewise `-ne`, `-lt`, `-le`,
  `-gt` and `-ge`.
- `! EXPR`: EXPR is false.
- `EXPR1 -a EXPR2`: both are true.

Quote variables (`[ -n "$x" ]`) so an empty value is still an argument.

## EXAMPLES

    if [ -d ~/src ]; then cd ~/src; fi
    [ "$answer" = yes ] && echo ok
    test -f ~/.zshrc || echo "no zshrc"

## SEE ALSO

true(1), false(1), expr(1), lsh(1)
