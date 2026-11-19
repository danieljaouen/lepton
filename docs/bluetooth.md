---
title: Bluetooth
order: 16
summary: Bluetooth keyboards, mice and headphones: pair and connect them from the command line or the classic desktop.
---

# Bluetooth

Lepton pairs and connects Bluetooth keyboards, mice and trackpads,
headphones, headsets and speakers. A paired keyboard or mouse works like a
USB one, at the console and on the desktop. Headphones become where
[sound](sound.html) plays.

```sh
bluetooth                         # on or off, and the paired devices
bluetooth scan                    # devices nearby (put yours in pairing mode first)
sudo bluetooth pair "MX Keys"     # pair, trust and connect (by name or address)
sudo bluetooth connect "MX Keys"
sudo bluetooth disconnect AA:BB:CC:DD:EE:FF
sudo bluetooth forget "MX Keys"   # unpair
sudo bluetooth off                # turn the radio off (and on)
bluetooth devices                 # every device Lepton knows of
```

Pairing, connecting and turning Bluetooth on or off change the system, so
they take [sudo](users.html). Scanning and looking don't.

## Pairing

Put the device in pairing mode (usually by holding its Bluetooth or
connect button until a light blinks), then pair it. A device you paired
reconnects by itself when you turn it on, after restarts too on an
installed system.

- **Keyboards** prove who they are by typing a number. Lepton shows it
  ("On MX Keys, type 482019 and press Enter"): type it on the Bluetooth
  keyboard itself and press Enter.
- **Mice and headphones** usually pair without a question. Older ones
  that want a PIN are asked for it; 0000 is the usual one.
- Some devices show a number and ask you to confirm it matches.

C-c stops pairing.

## On the classic desktop

With a Bluetooth adapter, the [classic desktop](desktop.html#the-classic-desktop)'s
taskbar shows the Bluetooth rune next to the volume: blue when Bluetooth
is on, grey when it's off. Click it for the devices: the connected ones
(highlighted), the paired ones, and new ones nearby. Lepton looks for
devices while the list is open.

Click a device to pair with it (a new one), connect it (a paired one) or
disconnect it (a connected one). A small terminal window does it with
the `bluetooth` command, which asks for your password if you aren't
root, and for the keyboard's number while pairing. The button below the
list turns Bluetooth off or on, or installs it the first time.

## Headphones and speakers

Connected headphones become where sound plays: Lepton's own sounds,
`play`, `beep`, and Firefox. The `volume` command, the volume keys and
the classic desktop's speaker set their volume. `sound` lists them;
`sound use 0` sends sound back to the sound card while they stay
connected, and `sound use bluetooth` brings it back to them. They play
in A2DP quality: there's no microphone (headset) mode.

## What you need

- **A USB Bluetooth adapter.** A Mac's built-in Bluetooth belongs to
  macOS: in UTM, plug in a USB Bluetooth adapter, turn on **Input → USB
  Sharing** in the VM's settings, and pick the adapter from the **USB**
  icon in the toolbar. Most USB adapters work: Realtek and MediaTek ones
  (their firmware is included) and Broadcom ones. Intel adapters need
  firmware Lepton doesn't include.
- **Bluetooth support** comes as an app: BlueZ (`bluetoothd`) with D-Bus,
  and bluez-alsa for headphones, from Alpine's packages (about 7.5 MB to
  download). The first `sudo bluetooth on` or `pair` installs it, as does
  the classic desktop's Install button or `sudo app install bluetooth`.
  It updates like [Firefox](apps.html#updates): Lepton checks every ten
  days and applies an update the next time Bluetooth starts.

## What it doesn't do yet

- Headset microphones and calls (HFP), file transfer (OBEX), phones and
  network sharing.
- Bluetooth MIDI and game controllers' extra features.

<!-- commands: bluetooth -->
