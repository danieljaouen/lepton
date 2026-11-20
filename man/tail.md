## DESCRIPTION

Print the last 10 lines of each FILE (or of standard input).

## OPTIONS

- `-n N`, `-N`: print the last N lines instead.
- `-n +N`: print everything from line N on.
- `-f`: after printing, keep watching the FILE and print what is
  appended to it as it arrives (checked twice a second). Stop with
  Ctrl-C.

## EXAMPLES

    tail -n 20 /var/log/messages
    tail -f /var/log/messages
    tail -n +2 data.csv

## SEE ALSO

head(1), journalctl(1), dmesg(1)
