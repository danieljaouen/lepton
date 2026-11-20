## DESCRIPTION

Add or remove a printer, or set the system's default printer. Printers
on the network are found without adding them; add one that can't be
found, by its address. Only root may do this: use `sudo`.

## OPTIONS

- `-p NAME -v URI`: add printer NAME at URI (`ipp://ADDRESS/ipp/print`,
  `ipps://...`). NAME is letters, digits, `_`, `.` and `-`.
- `-D DESCRIPTION`, `-L LOCATION`: what `lpstat` and Firefox show for it.
- `-E`: accepted (printers are always enabled).
- `-x NAME`: remove printer NAME.
- `-d NAME`: make NAME the system's default (each user may choose their
  own: `lpoptions -d`).

## FILES

- `/var/lib/lepton/printers`: the printers added.

## EXAMPLES

    sudo lpadmin -p office -v ipp://192.168.1.50/ipp/print -D "Office laser"
    sudo lpadmin -d office

## SEE ALSO

lpinfo(1), lpoptions(1), printers(1)
