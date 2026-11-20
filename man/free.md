## DESCRIPTION

Show the machine's memory: total, used, free, shared, buffers and cache,
and available (what programs can still get). A second line, `BEAM`,
shows the memory of the Erlang virtual machine that runs Lepton: its
total, and the parts used by processes, binaries, code and ETS tables.

Sizes are in KiB unless an option is given.

## OPTIONS

- `-h`: human-readable units (`512.0M`, `1.9G`).
- `-m`: MiB.
- `-k`: KiB (the default).

## SEE ALSO

top(1), df(1), uptime(1)
