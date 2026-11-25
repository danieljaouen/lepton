---
title: Users and sudo
order: 10
section: system
summary: Your account, logging in, sudo for administration, and managing accounts.
---

# Users and sudo

An installed Lepton has your own account. `lepton-install` asks for a user
name and a password, and every console then starts at a login prompt:

```
lepton login: alice
Password: ********
```

You log in to your home, `/home/NAME`, which starts with the image's
dotfiles. Your files are yours to change; the rest of the system needs
root. The live ISO has no accounts and logs `root` in automatically, as
before.

## sudo

Administrative commands run as root through `sudo`, which asks for **your**
password:

```sh
sudo poweroff
sudo svc start httpd
sudo lpm install jason
sudo le /etc/hosts
[sudo] password for alice:
```

After you've typed it, `sudo` remembers it for 5 minutes on that terminal.

| Command | What it does |
|---|---|
| `sudo COMMAND…` | run one command as root |
| `sudo su -` | a root login shell (in `/root`); `exit` or `C-d` takes you back to your own shell |
| `sudo -i` | the same |
| `sudo -s` | a root shell, staying where you are |
| `sudo -k` | forget the password now |
| `sudo -v` | ask for the password now, to start the 5 minutes |
| `sudo -l` | may you use sudo? |
| `sudo -S …` | read the password from standard input (scripts) |
| `sudo -n …` | never ask; fail instead |

Members of the `sudo` group may use sudo; the installer puts your account
in it.

## What needs root

Without sudo, these are refused with "permission denied":

- **Commands that change the system:** `poweroff`, `reboot`, `lepton-install`,
  `mount` (to mount), `umount`, `modprobe`, `rmmod`, `dhclient`,
  `hostname NAME`, `chown`, `useradd`, `userdel`, `sshd` and `crond`
  (`crontab` is for everyone: each user has their own; `crontab -u` is
  root's).
- **Changing services, packages and Wi-Fi:** `svc start|stop|restart|enable|disable|new|edit`,
  `lpm install|remove|update|upgrade|revert`, and `wifi connect|forget|setup`.
  Looking (`svc`, `svc logs`, `lpm list`, `wifi`, `wifi scan`) is for everyone.
- **Writing outside your home** and the temporary directories (`/tmp`,
  `/var/tmp`): the file commands (`touch`, `mkdir`, `rm`, `cp`, `mv`, `ln`,
  `chmod`, `tee`), shell redirections (`>`, `>>`) and saving in `le`.

Who you are comes from your login, not from `$USER`: `export USER=root`
changes nothing.

## Managing accounts

```sh
passwd                      # change your password
sudo useradd --sudo bob     # add an account (asks for its password); --sudo lets it use sudo
sudo passwd bob             # set someone's password
sudo userdel -r bob         # delete an account (-r: and its home)
id                          # who you are and your groups
```

Accounts are stored in `/var/lib/lepton` as `passwd`, `group` and `shadow`.
Passwords are kept only as salted PBKDF2-SHA512 hashes, in `shadow` (mode
600). `/etc/passwd` and `/etc/group` are rebuilt from them
at every boot.

## How far this goes

Accounts and sudo are enforced by Lepton's own commands, not by the
kernel. Lepton's whole userland is one Erlang VM running as root, so code
you run with `iex` or `elixir` can still do anything. (`mix` runs as
you, in a VM of its own.) Think of
accounts as protection against mistakes and a clear line between your
files and the system, not as a wall between untrusted users. Don't share
a Lepton machine with people you don't trust, or let them log in through
`ssh`: see [Limitations](limitations.html).

The files your commands create are yours, even though Lepton writes them
as root. That covers redirects (`>`, `>>`), `touch`, `mkdir`, `cp`,
`tee`, `ln -s`, files saved in `le`, downloads, git repositories (and the
folders `git clone` makes on the way), rsync, ssh keys and the hosts ssh
remembers (`~/.ssh`), so programs that run as you, such as Firefox,
`mix` and `ssh`, can change them. Writing to a file that already exists
keeps its owner, and so do files made with `sudo`.

Older releases left some of what they wrote in your home directory
root's (`~/.ssh`, a folder made by `git clone`), so that a program
running as you couldn't write there: `mix phx.new` said "permission
denied", say. Lepton gives such files back once, at the first boot of
1.25.2 or later. `sudo chown -R $USER:$USER ~` does the same by hand.

`su [-] [USER]` switches to another user in a new shell. Root may become
anyone; anyone else must type that user's password. Root has no password,
so become root with `sudo su -`.

<!-- commands: sudo su passwd useradd userdel whoami id chown -->
