## DESCRIPTION

Load the kernel module MODULE, after the modules it depends on, passing
it any PARAM=VALUE parameters. Only root may load modules: use `sudo`.

Lepton loads the drivers it needs at boot and when devices are plugged
in, so this is rarely needed.

## OPTIONS

- `-r MODULE`: remove MODULE instead, like `rmmod`.

## SEE ALSO

rmmod(1), lsmod(1), dmesg(1)
