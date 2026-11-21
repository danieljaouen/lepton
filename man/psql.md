## DESCRIPTION

PostgreSQL's SQL shell, `psql`, with Lepton's line editor in front of it.
It connects through the socket in `/run/postgresql` as the `postgres`
role, to the `postgres` database, unless options (or `PGUSER`, `PGHOST`,
`PGDATABASE`) say otherwise.

Type SQL statements, ending each with `;`; a statement can go on over
several lines (the prompt shows `-#`, or `'#` inside a string). Backslash
commands (`\l` databases, `\dt` tables, `\d NAME` a table, `\c DATABASE`
connect, `\x` expanded output, `\?` all of them) work as in psql. `\q`,
`quit` or `C-d` ends it. The line editor keeps a history in
`~/.psql_history` (Up, Down, `C-r`). `C-c` cancels a running statement.

With `-c`, `-f` or `-l`, or with input from a pipe or file, PostgreSQL's
`psql` runs on its own, as in a script.

## OPTIONS

PostgreSQL's psql options, among them:

- `-U ROLE`: connect as ROLE
- `-d DATABASE`: connect to DATABASE (or give it as the first argument)
- `-h HOST`, `-p PORT`: connect over TCP (a password is asked for in
  `PGPASSWORD` or `~/.pgpass`)
- `-c SQL`: run SQL and exit
- `-f FILE`: run the statements in FILE and exit
- `-l`: list the databases

## EXAMPLES

    psql
    psql myapp_dev
    psql -c 'select version()'
    psql myapp_dev < schema.sql
    PGPASSWORD=postgres psql -h localhost -c 'select 1'

## SEE ALSO

postgresql(1), mix(1)
