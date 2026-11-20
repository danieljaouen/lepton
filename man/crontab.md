## DESCRIPTION

Manage your crontab: the table of commands the `cron` service runs at
set times, as you, in your home directory. Each user has their own.

- `crontab -e`: edit your crontab in the editor (`le`). When you save
  and quit, it is checked and installed; if it has mistakes, they are
  shown by line and you can edit it again.
- `crontab -l`: print it.
- `crontab -r`: remove it.
- `crontab FILE`: install FILE as your crontab, replacing the old one.
  `crontab -` reads it from standard input.

## FORMAT

Each line is a schedule then a command:

    # m   h   dom mon dow   command
    */5   *   *   *   *     date >> ~/heartbeat.log
    0     3   *   *   1-5   rsync -a ~/notes/ /media/BACKUP/notes/
    @reboot                 svc status

The five fields are the minute (0-59), hour (0-23), day of the month
(1-31), month (1-12 or `jan`-`dec`) and day of the week (0-7, 0 and 7
being Sunday, or `sun`-`sat`). Each may be:

- `*`: any.
- a number, or a list `1,15,30`.
- a range `1-5`.
- a step: `*/10` (every tenth), `0-30/10` (0, 10, 20, 30), `5/15` (5,
  20, 35, 50).

When both the day of the month and the day of the week are restricted, a
day matching either runs the job (`0 9 1 * 1` is the 1st of the month
and every Monday).

Instead of the five fields: `@reboot` (when Lepton starts), `@hourly`,
`@daily` (or `@midnight`), `@weekly`, `@monthly`, `@yearly` (or
`@annually`).

Times are UTC, as `date` shows them.

Other lines:

- `NAME=value` sets an environment variable for the jobs after it.
- Blank lines and lines starting with `#` are ignored.

In a command, `%` ends the command: what follows is given to it as
standard input, each further `%` being a new line. Write `\%` for a `%`
(as in `date +\%F`).

## ENVIRONMENT OF JOBS

Jobs run with `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH` and `LANG`
set, plus your `NAME=value` lines, in your home directory, by the shell
without its startup files (`~/.zshrc` aliases are not loaded). What a
job prints, and a failing job's exit status, go to the cron log: `svc
logs cron`.

## OPTIONS

- `-u USER`: manage USER's crontab (root only).

## FILES

- `/var/lib/lepton/cron/USER`: the crontabs, kept on an installed system.

## EXAMPLES

    crontab -e
    crontab -l
    echo '0 * * * * date >> ~/hourly.log' | crontab -
    svc logs cron -f

## SEE ALSO

crond(1), svc(1), date(1), https://trylepton.app/docs/cron.html
