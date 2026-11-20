## DESCRIPTION

Print how much space each FILE takes (the current directory by
default): every directory below it with its total, in KiB. Sizes are the
files' lengths, with 4 KiB counted for each directory.

## OPTIONS

- `-s`: print only one total for each FILE.
- `-h`: print sizes in human-readable units (`4.0K`, `1.2M`, `3.4G`).
- `-a`: list files as well as directories.
- `-c`: accepted for compatibility.

## EXAMPLES

    du -sh ~
    du -h ~/src | sort -n

## SEE ALSO

df(1), ls(1)
