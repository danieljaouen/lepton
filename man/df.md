## DESCRIPTION

List the mounted file systems with their size, space used and
available, percentage used and mount point, as the kernel reports them
for each one. Sizes are in KiB (1K-blocks) unless `-h` is given.

With FILEs, list only the file systems they are on.

An installed system's data partition is mounted on `/persist` and also
appears at `/home`, `/root`, `/var/lib/lepton` and `/var/log`; it is
listed once, at `/persist` (name one of the others to see it there).
The live system's root (`/`) lives in memory, so its size and use are
the machine's memory.

## OPTIONS

- `-h`: print sizes in human-readable units (K, M, G).

## EXAMPLES

    df -h          # every file system
    df -h ~        # the one your home directory is on

## SEE ALSO

du(1), mount(1), lsblk(1), free(1)
