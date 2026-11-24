## DESCRIPTION

Set which way the mouse wheel (or a two-finger swipe on a trackpad)
scrolls on the desktop (Photon): in Firefox, terminal windows and `le`.

- `natural` (the default): the content follows your fingers, as on a Mac
  or an iPad. Swiping up (or turning the wheel down) moves the page up,
  showing what is below.
- `traditional`: the wheel moves the view, as on Linux and Windows:
  turning it down shows what is below.

UTM passes the wheel on to Lepton as it turns, so natural scrolling here
matches the Mac's. The setting is the system's, kept across reboots,
and takes effect at once.

## OPTIONS

- `mouse` or `mouse scroll`: say how scrolling is set.
- `mouse scroll natural`, `mouse scroll traditional`: set it.

## EXAMPLES

    mouse scroll traditional    # wheel down shows what is below
    mouse scroll natural        # back to the Mac's way

## SEE ALSO

keyboard(1), photon(1), classic(1)
