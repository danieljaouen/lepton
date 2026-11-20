---
title: SSH
order: 6
summary: SSH keys, an ssh client, known hosts and ~/.ssh/config, and an SSH server (keys only) to log in to Lepton.
---

# SSH

Lepton has an SSH client built on OTP's `ssh`. Use it to clone and push
private GitHub repositories with git, to log in to your own servers, and to
run commands on them.

## Set up GitHub in four commands

```sh
ssh-keygen                      # creates ~/.ssh/id_ed25519 and id_ed25519.pub
gh ssh-key add                  # uploads the public key (or paste it at github.com/settings/ssh/new)
ssh -T git@github.com           # "Hi you! You've successfully authenticated..."
git clone git@github.com:you/private-repo.git
```

`gh ssh-key add` needs a token with the `admin:public_key` scope (see
[gh](git.html#gh)). Without one, print the key with `cat
~/.ssh/id_ed25519.pub` and add it on GitHub's
[SSH keys page](https://github.com/settings/ssh/new). `gh ssh-key list`
shows the keys on your account.

After that, `git fetch`, `pull` and `push` use the key for every
`git@github.com:` remote. See [git over SSH](git.html#ssh-remotes) for
switching existing clones and for `gh repo clone`.

On the live ISO your key disappears at shutdown, so add it to GitHub only
from an [installed](getting-started.html#install-to-a-disk) system, which
keeps `/root/.ssh`. Give Lepton its own key rather than copying the one
from your Mac. You can then remove it from GitHub on its own.

## Keys

`ssh-keygen` creates an ed25519 key pair in OpenSSH format: the private key
is mode 600 and the public key goes next to it with a `.pub` suffix.

```sh
ssh-keygen -C "me@lepton"           # comment (default root@HOSTNAME)
ssh-keygen -f ~/.ssh/work_ed25519   # another file
ssh-keygen -l -f ~/.ssh/id_ed25519  # fingerprint
ssh-keygen -y -f ~/.ssh/id_ed25519  # print the public key
```

`ssh` and git try `~/.ssh/id_ed25519`, `id_ecdsa` and `id_rsa`, plus any
`IdentityFile` from `~/.ssh/config` or `-i FILE`. Keys made by OpenSSH
elsewhere work too, as long as they have **no passphrase**: Lepton can't
decrypt passphrase-protected keys yet, and says so when it finds one.

## Known hosts

Before sending your key, `ssh` checks the server's host key against:

- `~/.ssh/known_hosts` (plain and hashed entries, `[host]:port` for other
  ports);
- `/etc/ssh/ssh_known_hosts`, which ships with
  [GitHub's published keys](https://api.github.com/meta), so `github.com`
  is trusted out of the box.

The first connection to any other host shows its fingerprint and asks
before adding it, as OpenSSH does. git can't ask, so it stops with the
fingerprint and two ways to trust the host: run `ssh HOST` once, or add the
key yourself:

```sh
ssh-keyscan git.example.com >> ~/.ssh/known_hosts   # check the fingerprint first
ssh-keygen -R git.example.com                       # forget a host
```

A host whose key has **changed** is always refused, with a warning.

## The ssh command

```sh
ssh me@server                  # interactive shell on a remote terminal
ssh server uptime              # run one command; its exit status is ssh's
ssh -p 2222 -i ~/.ssh/work_ed25519 me@server
echo hello | ssh server cat    # piped input goes to the remote command
ssh -o StrictHostKeyChecking=accept-new server true
```

An interactive session uses the full terminal and follows window resizes
(serial terminals too). Type `~.` at the start of a line to disconnect.
`-T` skips the terminal, and `-t` asks for one even with a command.

## ~/.ssh/config

`Host` blocks with patterns (`*`, `?`, `!negation`) and the first value
wins, as in OpenSSH. These keywords are read:

| Keyword | Meaning |
|---|---|
| `HostName` | the real host name or address (`%h` is the alias) |
| `User` | login name (default `root`) |
| `Port` | port (default 22) |
| `IdentityFile` | a key to try; several add up |
| `StrictHostKeyChecking` | `ask` (default), `accept-new`/`no` to add new hosts silently, `yes` to refuse them |
| `UserKnownHostsFile` | instead of `~/.ssh/known_hosts` |

```
Host gh
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_ed25519
```

Aliases work everywhere, including in git remotes: `git clone
gh:you/repo.git`.

## Logging in to Lepton

Lepton has an SSH server too, `sshd`, so you can log in to it from
another computer on your network. It is **off** until you turn it on,
and it only takes **keys**: there is no password login, so nobody can
guess their way in.

On Lepton, put the other computer's public key (its
`~/.ssh/id_ed25519.pub`; copy it over on a USB drive, or paste it) in
the `authorized_keys` of the account you'll log in as, then start the
server:

```sh
mkdir -p ~/.ssh
cat id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sudo svc enable --now sshd     # now and at every boot
svc logs sshd                  # the host key's fingerprint, and the address to use
```

Then, from the other computer:

```sh
ssh alice@192.168.1.23         # a shell on Lepton
ssh alice@192.168.1.23 uptime  # one command; its exit status is ssh's
```

The first time, `ssh` shows Lepton's host key fingerprint. Check it
against the one in `svc logs sshd` before you answer yes.

- You log in as one of Lepton's [accounts](users.html), with a key in
  that account's `~/.ssh/authorized_keys` (one OpenSSH public key per
  line; options before the key are allowed and ignored). Root can log
  in the same way, with `/root/.ssh/authorized_keys`, which is how to
  reach the live ISO. An `authorized_keys` that group or others may
  write to is ignored.
- A login gets its own terminal, which follows your window's size:
  `le`, `tmux`, `top` and `sudo` work as on the console. Closing the
  connection ends everything the session started.
- `svc logs sshd` shows every login and every refused key.
- To copy files, use [rsync](rsync.html) from the other computer:
  `rsync -av dir/ alice@192.168.1.23:dir/`.
- The host key is made the first time `sshd` starts, in
  `/var/lib/lepton/ssh`. An installed system keeps it; the live ISO makes
  a new one each boot.
- Another port: `sudo svc edit sshd` and change `ExecStart=sshd` to
  `ExecStart=sshd -p 2222`.
- To turn it off again: `sudo svc disable --now sshd`.

In UTM, the VM must be reachable from your network: use **Bridged**
networking, or the Mac itself can reach a **Shared Network** VM at the
address `svc logs sshd` shows.

## Not supported

Logging in with a password (in both directions: keys only),
passphrase-protected keys, `ssh-agent`, agent and port forwarding, and
`scp`/`sftp` (to or from Lepton: use [rsync](rsync.html) instead).

<!-- commands: ssh ssh-keygen ssh-keyscan sshd -->
