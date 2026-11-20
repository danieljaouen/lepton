## DESCRIPTION

Print the log of the service NAME, as `svc logs NAME` does. Lepton keeps
one log per service, so `-u` is required.

## OPTIONS

- `-u NAME`: the service.
- `-n N`: only the last N lines.
- `-f`: keep printing new lines as they arrive, until Ctrl-C.

## EXAMPLES

    journalctl -u httpd -n 20
    journalctl -u hello -f

## SEE ALSO

svc(1), dmesg(1), tail(1)
