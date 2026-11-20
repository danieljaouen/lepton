## DESCRIPTION

Change the permission bits of each FILE. MODE is either:

- an octal number such as `755` or `0644`, or
- a symbolic change `[ugoa][+-=][rwx]`: who (`u` owner, `g` group, `o`
  others, `a` or nothing for all), an operation (`+` add, `-` remove,
  `=` set exactly) and the permissions (`r` read, `w` write, `x`
  execute).

To run a script by name it needs the execute bit: `chmod +x script.sh`.

## EXIT STATUS

0 on success, 1 if some FILE could not be changed.

## EXAMPLES

    chmod +x deploy.sh
    chmod 600 ~/.ssh/id_ed25519
    chmod go-w shared.txt

## SEE ALSO

chown(1), ls(1), stat(1)
