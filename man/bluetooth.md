## DESCRIPTION

Pair and connect Bluetooth keyboards, mice, trackpads, headphones and
speakers. A paired keyboard or mouse works like a USB one; connected
headphones become where sound plays. Paired devices reconnect by
themselves when turned on.

Looking and scanning are for everyone; the commands that change things
take `sudo`. Bluetooth is an app: the first change installs it.

## COMMANDS

- `bluetooth`, `bluetooth status`: on or off, and the paired devices.
- `scan [SECONDS]`: look for devices nearby for SECONDS (10 by default,
  at most 120). Put the device in pairing mode first.
- `devices`: every device Lepton knows of, with its address, kind and
  state (and battery level, when known).
- `pair DEVICE`: pair with DEVICE (a name or an address), trust it and
  connect it. A keyboard asks you to type a number on it; some devices
  ask for a PIN (usually 0000) or to confirm a number. Ctrl-C stops.
- `connect DEVICE`, `disconnect DEVICE`: connect or disconnect a paired
  device.
- `forget DEVICE`: unpair DEVICE.
- `on`, `off`: turn the Bluetooth radio on or off.

## EXAMPLES

    bluetooth scan
    sudo bluetooth pair "MX Keys"
    sudo bluetooth disconnect AA:BB:CC:DD:EE:FF

## SEE ALSO

sound(1), input(1), app(1), https://trylepton.app/docs/bluetooth.html
