## DESCRIPTION

Print the Linux kernel's message buffer: hardware found at boot, drivers
loading, USB devices coming and going, and kernel errors. Each line
starts with the time since boot in seconds.

Lepton also copies new kernel messages into its own log,
`/var/log/messages`, every few seconds.

## EXAMPLES

    dmesg | tail
    dmesg | grep -i usb

## SEE ALSO

journalctl(1), lsmod(1), usb(1)
