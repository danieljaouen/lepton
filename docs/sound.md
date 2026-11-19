---
title: Sound
order: 15
summary: Sound cards, the volume (volume, the volume keys, the classic desktop's speaker), and playing sounds.
---

# Sound

Lepton plays sound through the VM's sound device or a USB headset,
speaker or dock. There is one volume for everything: Lepton's own sounds
and [Firefox](apps.html) alike.

```sh
volume              # Volume: 50% on HDA Intel
volume 75           # set it (0 to 100)
volume +10          # louder (volume up / volume down: 5 at a time)
volume mute         # mute (unmute, toggle)
sound test          # three notes, to check you can hear it
play song.wav       # play a WAV file (C-c stops it)
beep 440 500        # a 440 Hz tone for half a second
```

The volume and mute are remembered, on an installed system across
restarts too.

## On the desktop

The volume keys on a keyboard (mute, volume down, volume up) work on the
desktop, in [Photon](desktop.html) and the classic desktop.

On the **classic desktop** a speaker sits next to the clock. Click it for
the volume control: click the slider to set the volume, and tick **Mute**
to silence everything. The speaker shows a red cross while sound is
muted. Click anywhere else to close the control.

## Sound cards

```text
$ sound
  0  HDA Intel                    volume: Master Playback Volume
* 1  USB Headset                  volume: PCM Playback Volume
(* plays sound: the card added last)
```

Sound plays on the card added last, so a USB headset takes over when you
plug it in and hands back when you unplug it, and so do
[Bluetooth headphones](bluetooth.html) when they connect (listed as
`bt`). `sound use 0` keeps sound on card 0 instead, `sound use bluetooth`
on the headphones; `sound use auto` goes back to the one added last.

The volume is set on the card's own volume control. A card without one
(virtio-sound) gets a volume control that works in software, marked
"software volume". Lepton's sounds and Firefox's follow it just the same.

**Drivers**: Intel HD Audio (UTM's and QEMU's usual sound device),
virtio-sound, and USB audio (headsets, speakers, sound cards, docks).
They load when the device appears. Bluetooth headphones and speakers
play through bluez-alsa; see [Bluetooth](bluetooth.html).

## In UTM

Give the VM a sound device in its settings (**Sound**: Intel HD Audio, or
VirtIO). Its sound comes out of your Mac. `mix lepton.qemu` gives its VM
Intel HD Audio, played on the Mac's speakers too.

## What it doesn't do yet

- Recording: microphones and line-in.
- Mixing: on most sound cards one program plays at a time, so while
  Firefox plays, `beep` and `play` may say the device is in use.
- Files other than WAV for `play` (Firefox plays the web's formats).
- Bluetooth headset microphones (headphones play; see [Bluetooth](bluetooth.html)).

<!-- commands: volume sound play beep -->
