## DESCRIPTION

Show Lepton's processes full screen, refreshed every two seconds, busiest
first. The header shows the uptime and load average, the number of
Lepton and Erlang processes, how busy the Erlang schedulers are (cpu),
and memory. For each process the table shows its PID, parent PID, state,
memory in KiB and reductions (the work it has done, in Erlang's units).

The System Monitor on the desktop runs `top` in a terminal window;
closing the window ends it.

## KEYS

- `q`, `Esc`, `Ctrl-C`: quit.

## SEE ALSO

ps(1), free(1), uptime(1), kill(1)
