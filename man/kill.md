## DESCRIPTION

Send a signal to each process PID, as shown by `ps`. The default
signal, TERM, ends the process. To act on a job of this shell, use
`fg`, `bg` or `jobs` and `ps` to find its PID.

## OPTIONS

- `-TERM`, `-15`: end the process (the default). Any signal not listed
  here is treated as TERM, so `-HUP` and `-INT` also end it.
- `-KILL`, `-9`: end the process immediately.
- `-STOP`, `-TSTP`: pause the process.
- `-CONT`: resume a paused process.
- `-l`: list the signal names.

PID 1 (init) cannot be signalled.

## EXIT STATUS

0 if every signal was sent, 1 otherwise.

## EXAMPLES

    kill 142
    kill -STOP 142; kill -CONT 142
    kill -9 142

## SEE ALSO

ps(1), pkill(1), pgrep(1), jobs(1), fg(1)
