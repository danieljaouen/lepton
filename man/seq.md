## DESCRIPTION

Print the integers from FIRST (default 1) to LAST, one per line,
counting by INCR (default 1). A negative INCR counts down. Nothing is
printed when the sequence is empty.

## EXAMPLES

    seq 5
    seq 0 10 100
    seq 10 -1 1
    for i in $(seq 3); do echo "round $i"; done

## SEE ALSO

yes(1), expr(1)
