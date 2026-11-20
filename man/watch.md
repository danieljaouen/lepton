## DESCRIPTION

Run COMMAND every two seconds and show its output full screen, under a
header naming the interval and the command, until you press `q` or
Ctrl-C. COMMAND is run by the shell, so pipes work (quote them).

## OPTIONS

- `-n SECS`: run every SECS seconds.

## EXAMPLES

    watch free -h
    watch -n 5 'ls -l ~/Downloads | tail'

## SEE ALSO

top(1), sleep(1)
