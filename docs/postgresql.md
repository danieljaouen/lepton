---
title: Databases (PostgreSQL)
order: 9
section: system
summary: PostgreSQL, the database Phoenix apps use: set up with one command (or a desktop icon), run as a service, with psql and PostgreSQL's tools.
---

# Databases: PostgreSQL

Lepton runs **PostgreSQL**, the database [Phoenix](web.html#a-new-phoenix-app-step-by-step) apps
(Ecto) use by default: Alpine Linux's build of PostgreSQL 18, installed
on demand like [Firefox](apps.html), and run as a
[service](services.html).

## Setting it up

```sh
sudo postgresql setup
```

or, on the [classic desktop](desktop.html), double-click **Install
PostgreSQL**. Either one:

1. installs PostgreSQL (26 packages from Alpine, about 18 MB to download,
   49 MB in `/var/lib/lepton/apps/postgresql`);
2. creates the database cluster in `/var/lib/lepton/postgresql/18`
   (UTF-8, with the `C.UTF-8` locale);
3. enables and starts the `postgresql` service, so it also starts at
   every boot.

Run it again at any time: it does only what is missing. Afterwards the
desktop icon is **PostgreSQL**, and opens `psql`.

On an installed system, PostgreSQL and its data are kept on the data
partition. On the live ISO they are kept in memory and are gone after a
reboot.

```sh
postgresql                  # installed? running? how to connect
svc status postgresql       # the service
svc logs postgresql         # PostgreSQL's log
sudo svc restart postgresql
```

## psql

`psql` is PostgreSQL's SQL shell, with Lepton's line editor in front of
it (history in `~/.psql_history`, `C-r` to search it). It connects as
the `postgres` superuser role.

```text
$ psql
psql 18.7: PostgreSQL's SQL shell. \? for help, \q or C-d to quit.
postgres=# create table notes (id serial primary key, body text);
CREATE TABLE
postgres=# insert into notes (body) values ('hello');
INSERT 0 1
postgres=# select * from notes;
 id | body
----+-------
  1 | hello
(1 row)

postgres=# \q
```

End each statement with `;`: a statement can run over several lines.
Backslash commands work as in psql everywhere: `\l` lists the databases,
`\c NAME` connects to one, `\dt` lists the tables, `\d NAME` describes
one, `\x` turns expanded output on and off. `C-c` cancels a statement
that is taking too long.

`psql -c SQL`, `psql -f FILE`, and input from a pipe or file run as a
script:

```sh
psql -c 'select version()'
psql myapp_dev < schema.sql
```

PostgreSQL's other tools are on the path once it's installed: `createdb`,
`dropdb`, `createuser`, `dropuser`, `pg_dump`, `pg_dumpall`, `pg_restore`,
`pg_isready`, `vacuumdb`, `reindexdb`, `clusterdb`, `pgbench`,
`pg_basebackup` and `pg_controldata`.

```sh
createdb myapp_dev
pg_dump myapp_dev > myapp.sql
```

## Connecting, and passwords

PostgreSQL listens on `localhost:5432`, for programs on this machine
only, and on a socket in `/run/postgresql`.

- **Through the socket** (`psql`, `createdb` and the rest), no password
  is asked: they connect as the `postgres` role (`PGUSER=postgres` is
  set in `/etc/lshrc`). Lepton's [accounts](users.html) aren't a boundary
  here, as elsewhere in Lepton.
- **Over TCP** (Phoenix and Ecto), a password is needed: the `postgres`
  role's is `postgres`, which is what a new Phoenix app's
  `config/dev.exs` expects, so it works as generated:

```elixir
config :myapp, Myapp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "myapp_dev"
```

For anything beyond development, give the role a password of your own,
and the app a role of its own:

```sh
psql -c "ALTER USER postgres PASSWORD 'a long secret'"
psql -c "CREATE ROLE myapp LOGIN PASSWORD 'another secret' CREATEDB"
```

To reach PostgreSQL from another computer, use an
[SSH tunnel](ssh.html) rather than opening the port. To open it anyway,
change `listen_addresses` in `/var/lib/lepton/postgresql/18/postgresql.conf`
and add a `host` line to `pg_hba.conf` next to it, then
`sudo svc restart postgresql`.

## How it runs

PostgreSQL refuses to run as root, so it runs as the `postgres` system
account (user ID 70, as on Alpine), which owns the cluster's files.
Stopping the service (and powering off) shuts PostgreSQL down cleanly:
open transactions are rolled back and everything is written out first.

Its settings are PostgreSQL's defaults, plus Lepton's at the end of
`postgresql.conf` (where it listens, and its log going to the
service's). Change them there, then restart the service.

## Removing it

```sh
sudo svc disable --now postgresql
sudo app remove postgresql
```

removes the programs and keeps the databases in
`/var/lib/lepton/postgresql`. To delete those too:
`sudo rm -r /var/lib/lepton/postgresql`.

<!-- commands: postgresql psql -->
