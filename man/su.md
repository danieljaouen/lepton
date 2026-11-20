## DESCRIPTION

Start a shell as USER (root by default). `exit` or Ctrl-D returns to
your own shell. You need USER's password, unless you are root. root has
no password, so to become root use `sudo su -` or `sudo -i`.

## OPTIONS

- `-`, `-l`, `--login`: a login shell, starting in USER's home with
  USER's environment.
- `-c COMMAND`: run COMMAND as USER instead of a shell.

## EXAMPLES

    sudo su -
    su bob
    su - bob -c 'ls ~'

## SEE ALSO

sudo(1), whoami(1), passwd(1)
