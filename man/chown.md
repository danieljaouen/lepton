## DESCRIPTION

Change the owner of each FILE to USER, and its group to GROUP when one
is given (otherwise to USER's own group). Only root may change owners:
use `sudo chown ...`.

## OPTIONS

- `-R`: change directories and everything in them, recursively. Symbolic
  links aren't followed: the links themselves change (also ones that point
  nowhere), not what they point at. A file it can't change is named, and
  the rest are changed anyway (the exit status is then 1).

## EXAMPLES

    sudo chown alice notes.txt
    sudo chown -R alice:alice /persist/shared
    sudo chown -R $USER:$USER ~      # your home directory, all of it yours

## SEE ALSO

chmod(1), id(1), sudo(1)
