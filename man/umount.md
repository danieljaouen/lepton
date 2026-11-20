## DESCRIPTION

Detach the file system mounted at each DIR. Only root may unmount: use
`sudo`. For a USB drive or SD card, `eject` is simpler and does not need
root.

## EXIT STATUS

0 on success, 32 if some DIR could not be unmounted (for example while
it is in use).

## SEE ALSO

mount(1), eject(1)
