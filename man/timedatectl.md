## DESCRIPTION

Show the clock and the time zone, set the zone, and turn NTP time
keeping on or off.

## COMMANDS

- `timedatectl`, `timedatectl status`: the local time and UTC, the time
  zone (its abbreviation and offset, and whether it was found
  automatically or set by hand), when the clock was last synchronised,
  with which server and how far off it was, and the `ntpd` service.
- `set-timezone ZONE`: use ZONE (such as `Europe/Paris`) from now on. The
  zone is no longer looked up. Root only.
- `set-timezone auto`: find the zone from the network's public address
  again (now, if the network is up). Root only.
- `list-timezones [TEXT]`: the zone names, or those containing TEXT.
- `set-ntp yes|no`: turn the `ntpd` service on or off, now and at boot.
  Root only.

## EXAMPLES

    timedatectl
    sudo timedatectl set-timezone America/New_York
    timedatectl list-timezones europe

## SEE ALSO

ntpd(1), date(1), https://trylepton.app/docs/time.html
