---
title: Services (svc)
order: 8
section: system
summary: Start, stop and restart long-running apps, like systemd.
---

# Services: svc

`svc` (also `systemctl`) starts, stops and restarts long-running apps,
restarts them when they fail, starts enabled ones at boot and keeps their
logs.

Services are system-wide and run as root, so starting, stopping,
enabling, creating and editing them takes [sudo](users.html). Anyone can
list them, see their status and read their logs.

```sh
svc                              # every service: state, PID, uptime
sudo svc start hello             # an example service that ships with Lepton
svc status hello                 # state, PID, restarts and the last log lines
svc logs hello -f                # follow its output (also: journalctl -u hello -f)
sudo svc stop hello              # stops it and every process it started
sudo svc new clock 'while true; do date; sleep 60; done'
sudo svc enable --now clock      # start now and at every boot
```

## Commands

| Command | What it does |
|---|---|
| `svc` / `svc list` | every service with its state, PID and uptime |
| `svc status NAME` | details and the last 10 log lines |
| `svc start / stop / restart NAME…` | control services |
| `svc enable / disable [--now] NAME` | start at boot (`--now` also starts or stops it) |
| `svc logs NAME [-n N] [-f]` | the log; `-f` follows it until `C-c` |
| `svc cat NAME` | show the unit file |
| `svc new NAME COMMAND…` | create `~/.config/lepton/services/NAME.service` (root's: `/root/.config/…`) |
| `svc edit NAME` | edit a unit in `le`; editing a shipped unit makes your own copy |
| `svc is-active / is-enabled NAME` | for scripts: exit status 0 means yes |
| `journalctl -u NAME [-n N] [-f]` | the same log, systemd-style |

## Unit files

A service is a unit file in systemd syntax, named `NAME.service`, in
`~/.config/lepton/services/` (yours; it persists on an installed system)
or `/etc/lepton/services/` (shipped with Lepton). Yours override a
shipped unit with the same name. `ExecStart` is any `lsh` command line.

```ini
[Unit]
Description=Static web server for ~/public (port 8080)

[Service]
ExecStart=mkdir -p ~/public && httpd -p 8080 ~/public
Restart=on-failure      # no (default) | on-failure | always
RestartSec=2            # seconds before a restart (default 1)
Environment=GREETING=hi "NAME=a b"
WorkingDirectory=~      # default: your home
TimeoutStopSec=5        # wait this long before killing on stop

[Install]
WantedBy=multi-user.target   # in a shipped unit: on by default
```

Other keys are ignored, and `svc status` lists them.

## How services behave

- Each run is a Lepton process tree under PID 1, so it shows in `ps`:
  `svc NAME`, and the service's command under it (`svc cron`, then
  `crond`).
  Stopping a service ends the whole tree (a terminate signal, then a kill
  after `TimeoutStopSec`).
- A clean exit leaves the service `inactive`; a non-zero exit or a kill
  marks it `failed`, and `Restart=` decides whether it comes back. The
  restarts stop after 5 starts in 10 seconds, as in systemd; a manual
  `svc start` resets that.
- Output goes to `/var/lib/lepton/log/NAME.log` (rotated at 1 MiB), so
  on an installed system the log survives reboots.
- Enabled services start at boot, once the data partition is mounted;
  the list is kept in `/var/lib/lepton/services`. Every service is
  stopped cleanly before power-off and reboot.

## Shipped services

- **hello**: says hello every two seconds. The tutorial uses it.
- **httpd**: serves `~/public` on port 8080 with `httpd`.
- **sshd**: the [SSH server](ssh.html#logging-in-to-lepton), keys only.
  Off until you run `sudo svc enable --now sshd`.

- **cron**: runs the jobs in everyone's [crontab](cron.html). On by
  default.
- **ntpd**: keeps the clock right and finds the [time zone](time.html).
  On by default.
- **cups**: [printing](printing.html): the queue, and IPP on
  127.0.0.1:631. On by default.
- **postgresql**: the [PostgreSQL](postgresql.html) database server, on
  localhost:5432. Off until `sudo postgresql setup` installs PostgreSQL
  and enables it.

Only `cron`, `ntpd` and `cups` start by themselves: a shipped unit with an `[Install]` section
(`WantedBy=`) is on until you disable it, as systemd's presets do. The
others start only when you start or enable them.

## httpd

`httpd [-p PORT] [DIR]` serves a directory over HTTP (and, with more
options, HTTPS in front of a web app: see [the web server](web.html)).
It makes a good first service:

```sh
sudo mkdir -p /root/public && echo 'hello' | sudo tee /root/public/index.html
sudo svc start httpd
curl http://localhost:8080/
```

## Limits

Only simple services: no dependencies between services (`After=`,
`Requires=`), timers, socket activation or resource limits. Everything
runs as `root`.

<!-- commands: svc journalctl httpd -->
