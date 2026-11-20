## DESCRIPTION

The print service: the queue of print jobs, each sent on to its printer
over IPP, and an IPP server on 127.0.0.1:631 (only this machine), as
CUPS has, which `lp`, `lpstat` and Firefox's print dialog use. It lists
the printers added with `lpadmin` and those found on the network (looked
for every minute). <http://localhost:631/> shows the printers and jobs.

You don't run it yourself: the `cups` service does, and is on by
default. Its log, `svc logs cups`, says what was printed and why a job
failed.

## SEE ALSO

lp(1), lpstat(1), lpadmin(1), svc(1)
