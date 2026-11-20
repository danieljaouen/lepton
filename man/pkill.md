## DESCRIPTION

End (send TERM to) every process whose command line contains PATTERN
(a plain string), except init and `pkill` itself.

## EXIT STATUS

0 if a process matched, 1 otherwise.

## EXAMPLES

    pkill top
    pkill 'sleep 60'

## SEE ALSO

pgrep(1), kill(1), ps(1)
