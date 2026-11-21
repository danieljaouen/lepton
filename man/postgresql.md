## DESCRIPTION

Set up and look after PostgreSQL, the database server Phoenix apps
(Ecto) use by default. PostgreSQL is Alpine Linux's build, installed as
an app (`app`), run as the `postgresql` service (`svc`) under the
`postgres` system account (PostgreSQL refuses to run as root).

With no argument (or `status`), say whether it is installed and running,
whether it starts at boot, where its data is, and how a Phoenix app
connects to it.

## COMMANDS

- `setup` (root): install PostgreSQL (about 18 MB to download), create
  the database cluster in `/var/lib/lepton/postgresql/18` (UTF-8,
  `C.UTF-8`), and enable and start the `postgresql` service. Run it again
  at any time: it does only what is missing. The classic desktop's
  **Install PostgreSQL** icon runs it.
- `server` (root): run the server in the foreground until it is stopped
  (the service runs this; use `svc start postgresql` instead).

## CONNECTING

The server listens on `localhost:5432` (this machine only) and on the
socket in `/run/postgresql`. Through the socket, `psql` and PostgreSQL's
tools connect without a password, as the `postgres` superuser role
(`PGUSER=postgres` is set in `/etc/lshrc`). Over TCP, a password is
needed: the `postgres` role's is `postgres`, what a new Phoenix app's
`config/dev.exs` expects. Change it with
`psql -c "ALTER USER postgres PASSWORD 'secret'"`.

Once installed, PostgreSQL's tools are on PATH (in `/usr/local/bin`):
`createdb`, `dropdb`, `createuser`, `dropuser`, `pg_dump`, `pg_dumpall`,
`pg_restore`, `pg_isready`, `vacuumdb`, `reindexdb`, `clusterdb`,
`pgbench`, `pg_basebackup` and `pg_controldata`.

## FILES

- `/var/lib/lepton/postgresql/18`: the cluster (`postgresql.conf`,
  `pg_hba.conf`); kept on the data partition of an installed system,
  in memory on the live ISO
- `/var/lib/lepton/apps/postgresql`: the programs
- `/etc/lepton/services/postgresql.service`: the service

## EXAMPLES

    sudo postgresql setup
    postgresql
    createdb myapp_dev
    psql myapp_dev
    svc logs postgresql
    pg_dump myapp_dev > backup.sql

## SEE ALSO

psql(1), svc(1), app(1), mix(1)
