## DESCRIPTION

The cron daemon. At the start of every minute it reads everyone's
crontab and runs the jobs that are due, each as its owner (see
`crontab`). `@reboot` jobs run once, when it first starts after Lepton
boots. If the machine was busy or asleep and minutes were missed, it
catches up on the last five.

You don't run `crond` yourself: the `cron` service runs it, and is on by
default. Its log, `svc logs cron`, shows each job as it starts
(`(alice) CMD (date)`), what the jobs print, and the exit status of jobs
that fail.

    svc status cron
    sudo svc disable --now cron   # turn cron off
    sudo svc enable --now cron    # and back on

## SEE ALSO

crontab(1), svc(1), journalctl(1)
