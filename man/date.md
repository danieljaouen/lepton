## DESCRIPTION

Print the date and time in the local time zone, as in `Fri Nov 20
14:03:12 EST 2026`, or in the given FORMAT. The zone is the system's
(see `timedatectl`), or the one in the `TZ` variable. In FORMAT, these
sequences are replaced:

- `%Y` year, `%y` year in two digits, `%m` month (01-12), `%d` day
  (01-31), `%e` day padded with a space, `%j` day of the year.
- `%H` hour (00-23), `%I` hour (01-12), `%p` AM or PM, `%M` minute,
  `%S` second, `%s` seconds since 1970-01-01.
- `%a` and `%A` the weekday, short and long; `%b` and `%B` the month,
  short and long.
- `%F` the same as `%Y-%m-%d`; `%T` the same as `%H:%M:%S`.
- `%Z` the zone's abbreviation (`EST`), `%z` its offset from UTC
  (`-0500`); `%%` a `%`.

## OPTIONS

- `-u`: show UTC instead of local time.
- `-I`: print the date in ISO 8601 format (`2026-11-20`).

## EXAMPLES

    date
    date -u
    TZ=Asia/Tokyo date
    date +%F
    cp notes.txt "notes-$(date +%Y%m%d).txt"

## SEE ALSO

cal(1), uptime(1), timedatectl(1)
