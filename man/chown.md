## DESCRIPTION

Change the owner of each FILE to USER, and its group to GROUP when one
is given (otherwise to USER's own group). Only root may change owners:
use `sudo chown ...`.

## OPTIONS

- `-R`: change directories and everything in them, recursively.

## EXAMPLES

    sudo chown alice notes.txt
    sudo chown -R alice:alice /persist/shared

## SEE ALSO

chmod(1), id(1), sudo(1)
