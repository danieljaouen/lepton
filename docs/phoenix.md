---
title: Hosting a Phoenix application
order: 9
section: network
summary: Build and run a Phoenix app on Lepton: PostgreSQL, Mix and Hex, development with live reload, and production as a service behind httpd with HTTPS.
---

# Hosting a Phoenix application

Lepton can build and host [Phoenix](https://www.phoenixframework.org/)
apps:

- [PostgreSQL](postgresql.html) is the database;
- `mix` runs in an Erlang VM of its own, as on any other system;
- [services](services.html) keep the app running;
- [`httpd`](web.html) puts HTTPS in front of it.

This page goes from nothing to a Phoenix app in production. Every step
here was run on Lepton with Phoenix 1.8.

Give the VM at least 4 GB of memory: compiling a new app's dependencies
takes a few minutes and a fair amount of memory. Lepton needs network
access to reach Hex.

## 1. Set up once

```sh
sudo postgresql setup                       # the database (localhost:5432)
sudo app install mix-tools                  # git and inotifywait, for mix
mix local.hex --force                       # Hex, Elixir's package manager
mix local.rebar --force                     # rebar3, for Erlang dependencies
mix archive.install hex phx_new --force     # the Phoenix generator
```

- `postgresql setup` installs PostgreSQL, creates its database cluster,
  and starts it as a service that also starts at boot. On the classic
  desktop, the **Install PostgreSQL** icon does the same.
- `mix-tools` holds programs Mix runs itself: git, for git
  dependencies (a new Phoenix app gets its icons, Heroicons, from
  GitHub), and inotifywait, for live reload. Only Mix sees them. At
  Lepton's prompt, `git` is still Lepton's own.
- Hex, rebar3 and the generator are kept in your home (`~/.mix`,
  `~/.hex`), as on any system.

## 2. Create the app

In a folder of your own (your home, or one you made in it), as yourself,
not with `sudo`:

```sh
cd ~
mix phx.new myapp --no-install
cd myapp
mix deps.get
mix ecto.create
```

`mix ecto.create` connects as the `postgres` role with the password
`postgres`, which is what the new app's `config/dev.exs` has, so the
generated settings work unchanged. It creates `myapp_dev`.

The first `mix` that compiles (here `ecto.create`) builds every
dependency, which takes a few minutes.

## 3. Develop

```sh
mix phx.server
```

The app listens on port 4000. Open <http://localhost:4000> in
[Firefox](apps.html) on Lepton's desktop. The first start downloads
esbuild and Tailwind, which build the JavaScript and CSS, and then
watches your files. Save a template in [`le`](editor.html) and the page
in Firefox reloads by itself (live reload).

`C-c` stops the server. To keep working in the same terminal, start it
in the background, `mix phx.server > /tmp/myapp.log 2>&1 &`, and stop it
with `pkill mix`.

To see the app from your Mac's browser, put `httpd` in front of it, as
in step 6 below. With [QEMU or UTM's shared network](networking.html),
the VM's ports are reached through port forwarding.

### What's different on Lepton

- **`iex -S mix` isn't available.** `iex` and `elixir` run in Lepton's
  own VM, and `mix` runs in a VM of its own. Use `mix run`, `mix test` and
  `mix phx.server`.
- **No C compiler.** Dependencies that compile C code (NIFs with a
  Makefile) can't be built. For `mix phx.gen.auth`, choose PBKDF2:
  `mix phx.gen.auth Accounts User users --hashing-lib pbkdf2`. The
  default, bcrypt, needs a C compiler.
- **`mix` runs as you**, so `_build` and `deps` are your files.
  [Services](services.html) run as root, so a production copy is root's
  (step 5).

## 4. Configure for production

Phoenix reads its production settings from the environment, in
`config/runtime.exs`:

| Variable | What it is |
|---|---|
| `DATABASE_URL` | `ecto://USER:PASSWORD@localhost/myapp_prod` |
| `SECRET_KEY_BASE` | a long random secret: `mix phx.gen.secret` |
| `PHX_HOST` | the name the app is reached at, like `myapp.example.com` |
| `PORT` | the port it listens on (4000) |

Give the app a database role of its own rather than using `postgres`:

```sh
psql -c "CREATE ROLE myapp LOGIN PASSWORD 'a long secret' CREATEDB"
```

When it sits behind `httpd` (step 6), make it listen on this machine
only: in `config/runtime.exs`, change the endpoint's
`ip: {0, 0, 0, 0, 0, 0, 0, 0}` to `ip: {127, 0, 0, 1}`.

## 5. Build and run it as a service

Services run as root, so build the production copy as root, in a
directory of its own, for example `/srv/myapp`:

```sh
sudo -i
git clone https://github.com/you/myapp.git /srv/myapp     # or copy it there
cd /srv/myapp
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix assets.deploy
export DATABASE_URL=ecto://myapp:SECRET@localhost/myapp_prod
mix ecto.create
mix ecto.migrate
mix phx.gen.secret | tail -1        # copy this: SECRET_KEY_BASE
```

Run `mix compile` before `mix assets.deploy`: compiling generates the CSS
and JavaScript that LiveView's colocated hooks add, which the asset
build includes. `assets.deploy` minifies the assets and fingerprints
them (`phx.digest`).

Then the service, `/root/.config/lepton/services/myapp.service`
(`svc edit myapp` creates it in `le`):

```ini
[Unit]
Description=myapp (Phoenix)

[Service]
ExecStart=mix phx.server
WorkingDirectory=/srv/myapp
Restart=on-failure
Environment=MIX_ENV=prod PORT=4000 PHX_HOST=myapp.example.com
Environment=DATABASE_URL=ecto://myapp:SECRET@localhost/myapp_prod
Environment=SECRET_KEY_BASE=PASTE_IT_HERE
```

```sh
svc enable --now myapp      # start it, and at every boot
svc status myapp
svc logs -f myapp           # the app's log (C-c to stop following)
```

The unit file holds the app's secrets, and it is root's: keep it that
way. Stopping the service (and powering off) stops the app's VM
gracefully. If it is still running 10 seconds later, it is killed.
At boot the app may start before PostgreSQL is ready. That's fine: Ecto
keeps trying to connect until it is.

## 6. HTTPS in front of it

`httpd` takes the browser's HTTPS, with a certificate for the app's
name, and passes each request on to the app, LiveView's WebSockets
included:

```sh
sudo httpd -p 80 -s 443 -r -x http://127.0.0.1:4000
```

As a service, with `/etc/lepton/httpd.toml` for several sites, and with
Let's Encrypt certificates for a real domain:
[Web server and HTTPS](web.html#a-new-phoenix-app-step-by-step) covers it
step by step, including the three settings Phoenix needs behind a proxy
(`url`, `check_origin` and `Plug.RewriteOn`).

## 7. Update the app

```sh
sudo -i
cd /srv/myapp && git pull
export MIX_ENV=prod
mix deps.get --only prod && mix compile && mix assets.deploy
DATABASE_URL=ecto://myapp:SECRET@localhost/myapp_prod mix ecto.migrate
svc restart myapp
```

## 8. Back up the database

```sh
pg_dump myapp_prod > /root/myapp-$(date +%F).sql     # a backup
psql myapp_prod < /root/myapp-2026-11-21.sql         # restore into an empty database
```

To make one every night, add a line to root's [crontab](cron.html):

```sh
0 3 * * * pg_dump myapp_prod > /root/backups/myapp.sql
```

## When something goes wrong

| What you see | What to do |
|---|---|
| `the "git" executable is not available` | `sudo app install mix-tools` |
| `inotify-tools is needed` (no live reload) | `sudo app install mix-tools`, then restart `mix phx.server` |
| `connection refused` on port 5432 | `postgresql` says whether it is running; `sudo svc start postgresql` |
| `password authentication failed` | the role's password differs from `config/dev.exs` (`postgres` unless you changed it) |
| a dependency fails with `make` or `cc` | it compiles C code: use a pure-Elixir alternative |
| `could not find static manifest` (500 errors in production) | run `mix compile` and then `mix assets.deploy` with `MIX_ENV=prod` |
| the service restarts over and over | `svc logs myapp`: often a missing variable in `Environment=` |
