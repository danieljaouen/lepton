## DESCRIPTION

Mount DIR of another machine on MOUNTPOINT, over SSH: its files then
appear under MOUNTPOINT, for every program (`ls`, `le`, `cp`, Firefox).
Reading and writing them goes over SFTP, on the SSH connection `ssh`
would make, with your keys, `~/.ssh/config`, known hosts, jump hosts and
proxies. DIR is relative to your home there (all of it when left out).

MOUNTPOINT must be an existing directory you may write to (in your home,
say). The files appear as yours. `sshfs` returns once mounted, and a
process stays to serve the mount (it shows in `ps`). Unmount with
`fusermount -u MOUNTPOINT`.

The other machine needs an SFTP server: OpenSSH's (Linux, macOS with
Remote Login on) and Lepton's `sshd` have one.

## OPTIONS

- `-p PORT`: the SSH port.
- `-o OPTION=VALUE,...`: `port`, `IdentityFile`, `ProxyJump`,
  `ProxyCommand` and `StrictHostKeyChecking`, as for `ssh`. Other
  options are accepted and ignored.

## NOTES

While a program waits for the other machine (a slow network), other
file operations in Lepton may wait too: Lepton's programs share one file
server. Hard links and device files can't be made on the mount. Files
are written as they change (no caching beyond a second for names and
attributes).

## EXAMPLES

    mkdir ~/server
    sshfs me@server.example.com:projects ~/server
    ls ~/server
    fusermount -u ~/server

    sshfs -o ProxyJump=bastion me@server.internal: ~/inside

## SEE ALSO

fusermount(1), ssh(1), rsync(1), https://trylepton.app/docs/ssh.html#mounting-another-machine-sshfs
