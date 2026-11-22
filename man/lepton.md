## DESCRIPTION

Run a Lepton command line. At Lepton's prompt it simply runs it; its use
is from native programs. Lepton's own commands (`svc`, `app`, `vm`,
Lepton's `git`, ...) are functions in Lepton's Erlang VM, not files, so a
native program, such as Claude Code's bash, can't run them as it runs a
program. There, `lepton` is `/usr/bin/lepton`, which sends the command
line to Lepton over a socket only you can open
(`/run/lepton/bridge/UID/socket`); Lepton runs it in `lsh` as you, and
`lepton` prints its output and exits with its status.

The command gets no terminal, so programs that need one (`le`,
`vm console`) don't work this way. Its standard input is empty unless
`-i` is given.

## OPTIONS

- `-c LINE`: run LINE as a command line (pipes, `;`, `&&`).
- `-i`: pass this program's standard input to the command.

## EXAMPLES

    lepton svc status
    lepton vm start test
    lepton -c 'vm log test | tail -5'
    echo hello | lepton -i tr a-z A-Z

## FILES

- `/usr/bin/lepton`: the client, an escript.
- `/run/lepton/bridge/UID/socket`: each user's socket.

## SEE ALSO

claude(1), lsh(1), https://trylepton.app/docs/claude-code.html
