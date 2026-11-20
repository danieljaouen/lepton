## DESCRIPTION

List the mounted file systems with their size, space used and
available, percentage used and mount point. Sizes are in KiB unless
`-h` is given.

## OPTIONS

- `-h`: print sizes in human-readable units.

## BUGS

Lepton's root file system lives in memory, so sizes are reported from
the machine's memory rather than from each device.

## SEE ALSO

du(1), mount(1), lsblk(1), free(1)
