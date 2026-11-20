## DESCRIPTION

Create the user account NAME with a home directory, `/home/NAME`, that
starts with the system's dotfiles. You are asked for the account's
password. Only root may add accounts: use `sudo`. `adduser` is the same
command.

## OPTIONS

- `--sudo`: let the account use `sudo` (add it to the `sudo` group).
- `-c FULL_NAME`: the account's full name.
- `--password-stdin`: read the password from standard input.

## EXAMPLES

    sudo useradd --sudo -c "Bob Smith" bob

## SEE ALSO

userdel(1), passwd(1), id(1), sudo(1)
