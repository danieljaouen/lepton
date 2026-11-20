## DESCRIPTION

List Lepton's processes: every program and shell running in Lepton,
with its process ID (PID), parent's PID (PPID), controlling terminal
(TTY), state (STAT: `S` running or sleeping, `T` stopped), the time
since it started, and its command line.

Lepton's processes are Erlang processes inside one virtual machine, so
they are not the Linux kernel's processes. Those, such as Firefox and
kernel threads, are listed too with `-e`, with PIDs prefixed by `k`.

## OPTIONS

- `-e`, `-A`, `aux`: also list the Linux processes.
- `-f`: accepted for compatibility.

## EXAMPLES

    ps
    ps aux | grep firefox

## SEE ALSO

top(1), kill(1), pgrep(1), jobs(1)
