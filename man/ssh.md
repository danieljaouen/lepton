## DESCRIPTION

Log in to the SSH server HOST and open a shell there, or run COMMAND on
it and exit with COMMAND's exit status. Standard input is passed to the
remote command, so `echo hi | ssh host cat` works.

Authentication uses keys only: `~/.ssh/id_ed25519`, `id_ecdsa` and
`id_rsa`, any `IdentityFile` from `~/.ssh/config`, and any `-i` KEY.
Keys protected by a passphrase are not supported. The server's host key
is checked against `~/.ssh/known_hosts` and `/etc/ssh/ssh_known_hosts`
(which includes GitHub's keys). An unknown host's fingerprint is shown
and you are asked before it is added; a host whose key has changed is
refused.

In an interactive session the remote side gets a terminal that follows
window resizes. Type `~.` at the start of a line to disconnect.

## OPTIONS

- `-p PORT`: connect to PORT (default 22).
- `-i KEY`: try the private key in file KEY (may be repeated).
- `-l USER`: log in as USER (or write `USER@HOST`).
- `-o StrictHostKeyChecking=VALUE`: `ask` (the default), `accept-new`
  or `no` (add new hosts without asking) or `yes` (refuse unknown
  hosts).
- `-J JUMP[,JUMP...]`: go through these jump hosts (`[USER@]HOST[:PORT]`),
  each reached over SSH through the one before (ProxyJump).
- `-W HOST:PORT`: instead of a shell, connect standard input and output
  to HOST:PORT through the server (for ProxyCommand).
- `-o ProxyJump=...`, `-o ProxyCommand=COMMAND`: as in `~/.ssh/config`.
  The command's input and output are the connection; `%h`, `%p`, `%r`
  and `%n` are the host, port, user and the name given.
- `-T`: do not ask for a terminal.
- `-t`: ask for a terminal even when running COMMAND.
- `-q`, `-v`, `-n`, `-A`, `-x`, `-4`, `-6`: accepted for compatibility.

## FILES

- `~/.ssh/config`: `Host` blocks with `HostName`, `User`, `Port`,
  `IdentityFile`, `StrictHostKeyChecking`, `UserKnownHostsFile`,
  `ProxyJump` and `ProxyCommand` (`none` to turn one off), as in
  OpenSSH.

## PROXIES

The way to the server is, first that applies: a ProxyCommand, a
ProxyJump chain, the system's proxy chain (see `proxy`) or the
`all_proxy` variable, or directly. Host keys are checked under the
server's own name and port, whichever way the connection goes.
- `~/.ssh/known_hosts`: the hosts you have trusted.

## EXIT STATUS

The exit status of the remote command, or 255 if the connection failed.

## EXAMPLES

    ssh -T git@github.com
    ssh me@server
    ssh -p 2222 -i ~/.ssh/work_ed25519 me@server uptime
    ssh -J bastion me@server.internal
    ssh -o ProxyCommand='nc -X connect -x proxy:3128 %h %p' me@server

## SEE ALSO

ssh-keygen(1), ssh-keyscan(1), sshd(1), rsync(1), proxy(1), nc(1), git(1), gh(1)
