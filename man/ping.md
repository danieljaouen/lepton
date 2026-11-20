## DESCRIPTION

Send ICMP echo requests to HOST, one a second, and print the time each
reply took, then a summary with the packet loss. A reply not received
within two seconds is reported as a timeout.

## OPTIONS

- `-c COUNT`: send COUNT requests (4 by default).

## EXIT STATUS

0 if any reply was received, 1 if none was, 2 on errors (such as an
unknown host).

## EXAMPLES

    ping 1.1.1.1
    ping -c 1 github.com

## SEE ALSO

nslookup(1), ip(1), curl(1)
