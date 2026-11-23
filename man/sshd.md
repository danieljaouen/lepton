## DESCRIPTION

The SSH server: log in to Lepton from another computer on your network,
or run commands on it, with `ssh`. Only root may run it, and it is
**off** until you turn it on. Run it as a service:

    sudo svc enable --now sshd    # start it now and at every boot
    sudo svc disable --now sshd   # stop it, and keep it off

**Keys only.** `sshd` never accepts a password: it offers no password or
keyboard-interactive login at all. You log in as one of Lepton's
accounts with a key listed in that account's `~/.ssh/authorized_keys`,
one public key per line, as OpenSSH writes them (`ssh-ed25519 AAAA...
comment`). Root may log in the same way, with a key in
`/root/.ssh/authorized_keys`. An `authorized_keys` file that group or
others can write to is ignored.

To set it up, from the other computer, copy its public key over (with
a USB drive, the clipboard, or `curl`), then on Lepton:

    mkdir -p ~/.ssh
    cat id_ed25519.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    sudo svc enable --now sshd
    svc logs sshd                 # the host key's fingerprint and the address to use

Then, on the other computer: `ssh alice@ADDRESS`. The first time, it
shows Lepton's host key fingerprint: check it against the one in `svc
logs sshd` before you answer yes.

A login gets a shell on a terminal of its own, which follows the
window's size; `ssh alice@ADDRESS COMMAND` runs COMMAND and returns its
exit status. Closing the connection ends everything the session
started, as a hangup does. Lepton can be a jump host: a client's `ssh -J
lepton server` or `-L` tunnels go on through it, as OpenSSH allows.
SFTP is offered, so `sftp`, `scp` and `sshfs` work from other computers:
each account sees only its home (root, everything). Remote forwarding
(`-R`) is not offered, but `rsync` works: a Mac's `rsync -av dir/
alice@ADDRESS:dir/` runs Lepton's rsync on this side.

The host key, an ed25519 key, is made the first time `sshd` starts. An
installed system keeps it, so clients recognise Lepton after a restart;
the live ISO makes a new one each boot.

Key exchange is post-quantum first: `mlkem768x25519-sha256` (ML-KEM-768
with X25519, which OpenSSH 10 prefers and warns without), then
`curve25519-sha256` and the other usual ones for older clients.

## OPTIONS

- `-p PORT`: listen on PORT instead of 22. To keep it in the service,
  `sudo svc edit sshd` and change the `ExecStart` line to `sshd -p
  PORT`.

## FILES

- `~/.ssh/authorized_keys`: the keys that may log in to an account.
- `/var/lib/lepton/ssh/ssh_host_ed25519_key`, `.pub`: the host key.
- `/etc/lepton/services/sshd.service`: the service.

## EXAMPLES

    sudo svc enable --now sshd
    svc logs sshd -f
    ssh-keygen -l -f /var/lib/lepton/ssh/ssh_host_ed25519_key.pub

## SEE ALSO

ssh(1), ssh-keygen(1), rsync(1), svc(1), useradd(1), https://trylepton.app/docs/ssh.html#logging-in-to-lepton
