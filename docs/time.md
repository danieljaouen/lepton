---
title: Time and time zones
order: 11
summary: The clock is kept right with NTP, and the time zone is found from your network, or set by hand.
---

# Time and time zones

Lepton keeps its clock right by itself, and shows times in your time
zone. Both are the work of the `ntpd` service, which is on by default.

```sh
timedatectl                              # local time, UTC, the zone, the last sync
date                                     # Fri Nov 20 14:03:12 EST 2026
timedatectl set-timezone Europe/Paris    # choose the zone yourself
timedatectl set-timezone auto            # back to finding it automatically
timedatectl list-timezones america       # zone names
```

## The clock

`ntpd` asks NTP servers for the time (`pool.ntp.org` and
`time.cloudflare.com`; change them in `/etc/ntp.conf`), keeps the answer
with the shortest round trip, and sets the clock when it is off by more
than 128 ms. It asks every 15 seconds until it has the time, then less
and less often, up to every 17 minutes, while the clock stays right. An
answer has to be to the question it asked, from a server that is itself
synchronised.

The hardware clock is updated too, so the next boot starts close to the
right time. `svc logs ntpd` shows each correction, and `timedatectl`
when the clock was last checked, against which server, and how far off
it was.

To turn time keeping off (in a VM whose host sets its clock, say):
`sudo timedatectl set-ntp no`. `sudo ntpd -q` sets the clock once.

## The time zone

Unless you choose one, the time zone is **automatic**: `ntpd` looks it
up from your network's public address (a GeoIP lookup, at
<https://ipapi.co>, or <http://ip-api.com> if that fails) when the
network comes up, and again every six hours, so it follows you when you
travel. Until it has been found it is **UTC**; when the network is down
the zone found last stays.

`sudo timedatectl set-timezone Europe/Paris` sets the zone by hand: no
lookups are made after that. `sudo timedatectl set-timezone auto` goes
back to automatic.

The zone is kept in `/var/lib/lepton/timezone`, so on an installed system
it survives restarts. It applies to:

- `date`, `cal`, `uptime`, `ls -l`, `stat`, `svc` and `journalctl` logs,
- [cron](cron.html): jobs run at local times,
- git: commits record your UTC offset,
- tmux's status line and the [classic desktop](desktop.html)'s clock,
- native programs such as [Firefox](apps.html), through `/etc/localtime`.

For one command, set `TZ`: `TZ=Asia/Tokyo date`. The zones are the IANA
database's, in `/usr/share/zoneinfo`, daylight saving time included.

<!-- commands: timedatectl ntpd date -->
