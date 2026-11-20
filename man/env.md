## DESCRIPTION

With no COMMAND, print the environment (after applying any NAME=VALUE
assignments), one `NAME=VALUE` per line, sorted.

With a COMMAND, run it with the environment changed by the assignments,
leaving the shell's own environment as it was.

## EXAMPLES

    env | grep PATH
    env NO_COLOR=1 ls

## SEE ALSO

printenv(1), export(1), unset(1)
