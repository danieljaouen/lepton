## DESCRIPTION

With no arguments, list the mounted file systems: device, mount point,
type and options.

Otherwise attach the file system on SOURCE (a device such as
`/dev/sdb1`) at the directory DIR. Only root may mount: use `sudo`.

USB drives and SD cards are mounted for you under `/media` when they
are plugged in, so `mount` is rarely needed.

## OPTIONS

- `-t TYPE`: the file system type, such as `vfat`, `exfat` or `ext4`.
  By default it is detected.
- `-o OPTS`: mount options, such as `ro`.

## EXIT STATUS

0 on success, 32 if the mount failed.

## EXAMPLES

    mount
    sudo mount -t ext4 /dev/sdb2 /mnt

## SEE ALSO

umount(1), lsblk(1), eject(1), df(1)
