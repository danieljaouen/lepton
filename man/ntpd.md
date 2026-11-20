## DESCRIPTION

Keep the system clock right with NTP, and find the time zone. The
`ntpd` service runs it, and is on by default; you rarely run it
yourself.

It asks the time servers (SNTP: one UDP packet each way) and keeps the
answer with the shortest round trip. A reply must answer the question
asked, from a server that is itself synchronised. When the clock is off
by more than 128 ms, `ntpd` sets it (and the hardware clock). It asks
every 15 seconds until it has the time, then from every minute up to
every 17 minutes while the clock stays right.

While the time zone is automatic (see `timedatectl`), it also looks the
zone up from the network's public address (GeoIP), when the network is
up and every six hours after.

Only root may run it.

## OPTIONS

- `-q`: set the clock once, print the offset, and exit.
- `-p SERVER`: ask SERVER instead of the configured servers (may be
  repeated).

## FILES

- `/etc/ntp.conf`: the servers, one `server NAME` (or `pool NAME`) line
  each. By default `pool.ntp.org` and `time.cloudflare.com`.
- `/var/lib/lepton/timezone`: the time zone.

## EXAMPLES

    sudo ntpd -q
    sudo ntpd -q -p time.google.com
    svc logs ntpd

## SEE ALSO

timedatectl(1), date(1), svc(1), https://trylepton.app/docs/time.html
