## DESCRIPTION

Run COMMAND as root, after asking for your own password. Once you have
typed it, `sudo` remembers it for 5 minutes on that terminal. Members of
the `sudo` group may use `sudo`; the installer puts your account in it.
On the live ISO you are already root.

## OPTIONS

- `-i`: start a root login shell, in `/root` (like `sudo su -`).
- `-s`: start a root shell, staying in the current directory.
- `-k`: forget the password now.
- `-v`: ask for the password now, to start the 5 minutes.
- `-l`: say whether you may use `sudo`.
- `-S`: read the password from standard input (for scripts).
- `-n`: never ask for a password; fail instead.

## ENVIRONMENT

The command gets `SUDO_USER` and `SUDO_UID`, naming who ran `sudo`.

## EXAMPLES

    sudo poweroff
    sudo le /etc/hosts
    sudo -i

## SEE ALSO

su(1), passwd(1), id(1), https://trylepton.app/docs/users.html
