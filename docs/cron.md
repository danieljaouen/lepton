---
title: Scheduled jobs (cron)
order: 9
section: system
summary: Run commands at set times with crontab and the cron service.
---

# Scheduled jobs: cron

The `cron` service runs commands at set times: backups at night, a
report every hour, something at every boot. Each user has a **crontab**,
a table of times and commands, and the jobs in it run as that user, in
their home directory.

```sh
crontab -e        # edit yours (in le); it's checked when you save
crontab -l        # show it
crontab -r        # remove it
svc logs cron     # what ran, and what the jobs printed
```

## The format

```
# m   h   dom mon dow   command
*/5   *   *   *   *     date >> ~/heartbeat.log
0     3   *   *   1-5   rsync -a ~/notes/ /media/BACKUP/notes/
30    8   1   *   *     echo "first of the month" >> ~/reminders.txt
@reboot                 date >> ~/boots.log
```

The five fields are minute, hour, day of the month, month and day of the
week:

| Field | Values |
|---|---|
| minute | 0-59 |
| hour | 0-23 |
| day of month | 1-31 |
| month | 1-12, or `jan`-`dec` |
| day of week | 0-7 (0 and 7 are Sunday), or `sun`-`sat` |

Each field is `*` (any), a number, a list (`1,15`), a range (`1-5`) or a
step (`*/10`, `0-30/10`). When both day fields are restricted, a day
matching either runs the job. `@hourly`, `@daily`, `@weekly`,
`@monthly`, `@yearly` and `@reboot` (when Lepton starts) can stand in
for the five fields.

Times are **local**, in the time zone `date` shows (see [time](time.html)): a job at
`0 9 * * *` runs at 9 in the morning where you are.

- `NAME=value` lines set environment variables for the jobs after them.
- In a command, `%` starts its standard input (write `\%` for a percent
  sign, as in `date +\%F`).
- Jobs run without your `~/.zshrc`, so use commands, not aliases.

## The log

What a job prints goes to the cron log, not to a terminal or mail:

```sh
svc logs cron       # recent lines
svc logs cron -f    # follow it
```

```text
Nov 20 03:00:00 cron[105]: (alice) CMD (rsync -a ~/notes/ /media/BACKUP/notes/)
Nov 20 03:00:01 cron[105]: (alice) exited with status 23: rsync -a ~/notes/ /media/BACKUP/notes/
```

## The service

`cron` is on by default: it starts at boot and reads every crontab each
minute, so a change takes effect at the next minute. To turn it off:

```sh
sudo svc disable --now cron
```

Crontabs are kept in `/var/lib/lepton/cron`, so on an installed system
they survive restarts. Root manages anyone's with `crontab -u USER`.

<!-- commands: crontab crond -->
