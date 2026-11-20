## DESCRIPTION

Start, stop and restart services: long-running programs that run in the
background, restart when they fail, start at boot if enabled, and keep
their output in a log. `systemctl` is the same command.

Anyone may list services and read their status and logs; starting,
stopping, enabling, creating and editing them take `sudo`.

## COMMANDS

- `svc`, `svc list`: every service, with its state, PID and uptime.
- `status NAME...`: state, PID, restarts and the last 10 log lines.
- `start NAME...`, `stop NAME...`, `restart NAME...`: control services.
  Stopping ends the service and everything it started.
- `enable [--now] NAME...`, `disable [--now] NAME...`: start (or no
  longer start) at boot; `--now` also starts or stops it now.
- `logs NAME [-n N] [-f]`: the log (its last N lines); `-f` follows it
  until Ctrl-C.
- `cat NAME`: print the unit file.
- `new NAME COMMAND...`: create a unit that runs COMMAND.
- `edit NAME`: edit a unit in `le` (editing a shipped unit makes your
  own copy).
- `is-active NAME`, `is-enabled NAME`: for scripts: exit status 0 means
  yes.

## UNIT FILES

A service is a file `NAME.service` in systemd syntax, in
`~/.config/lepton/services/` (yours, which win) or
`/etc/lepton/services/` (shipped). The `[Service]` keys read are
`ExecStart` (a shell command line), `Restart` (`no`, `on-failure`,
`always`), `RestartSec`, `Environment`, `WorkingDirectory` and
`TimeoutStopSec`; `[Unit]` has `Description`. A shipped unit with
`WantedBy=` in `[Install]` is enabled by default (`cron` is), until
disabled.

    [Service]
    ExecStart=httpd -p 8080 ~/public
    Restart=on-failure

## FILES

- `/var/lib/lepton/log/NAME.log`: each service's log.
- `/var/lib/lepton/services`: the enabled services.

## EXAMPLES

    svc
    sudo svc start hello
    svc logs hello -f
    sudo svc new clock 'while true; do date; sleep 60; done'
    sudo svc enable --now clock

## SEE ALSO

journalctl(1), httpd(1), sshd(1), crond(1), ps(1), https://trylepton.app/docs/services.html
