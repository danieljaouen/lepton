## DESCRIPTION

Unmount a FUSE filesystem (one `sshfs` mounted), so that MOUNTPOINT is an
empty directory again and the process serving it ends. You may unmount
what is in a directory you can write to; root may unmount anything
(with `umount` too).

## OPTIONS

- `-u`: unmount (required).

## EXIT STATUS

0 on success, 1 if MOUNTPOINT isn't a FUSE mount or is busy.

## SEE ALSO

sshfs(1), umount(1)
