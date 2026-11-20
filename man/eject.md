## DESCRIPTION

Unmount a USB drive or SD card, flushing everything written to it, so
that it is safe to remove. Name it by its device (`sdb`, `/dev/sdb1`)
or by its mount point or a directory in it (`/media/USB`). With no
argument, eject the only removable drive that is mounted.

All the mounted partitions of the drive are unmounted.

## EXIT STATUS

0 on success, 1 if nothing could be ejected (for example when several
drives are mounted and none was named).

## EXAMPLES

    eject
    eject /media/SANDISK

## SEE ALSO

lsblk(1), umount(1), mount(1)
