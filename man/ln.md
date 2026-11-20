## DESCRIPTION

Create LINK pointing to TARGET. Without options this is a hard link: a
second name for the same file. With `-s` it is a symbolic link, which
stores TARGET as text (a relative TARGET is relative to LINK's
directory).

## OPTIONS

- `-s`: make a symbolic link.
- `-f`: remove an existing LINK first.

## EXAMPLES

    ln -s ~/.dotfiles/zshrc ~/.zshrc
    ln -sf /persist/data ~/data

## SEE ALSO

readlink(1), realpath(1), ls(1)
