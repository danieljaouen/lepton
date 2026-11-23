---
title: USB, hubs and displays
order: 13
section: hardware
summary: USB hubs and docks, devices plugged in while Lepton runs, and second displays for the desktop (extended or mirrored).
---

# USB, hubs and displays

## USB devices and hubs

Plug things in directly or through a hub (or hubs of hubs) and they work
the same way. The Linux kernel enumerates every hub's ports. When a device
appears, Lepton loads its driver within a second:

| Device | Driver | What you get |
|---|---|---|
| keyboards, mice, touchpads, tablets | `usbhid` and others | they work at once (below) |
| USB sticks, drives and card readers | `usb-storage`, `uas` | mounted under `/media` ([USB drives and SD cards](storage.html)) |
| Wi-Fi adapters | see [Networking](networking.html) | a wireless interface |
| Ethernet ports (docks, adapters) | `r8152`, `ax88179_178a`, `asix`, `cdc_ether`, `cdc_ncm` | an interface, configured with DHCP |
| USB display adapters | `udl`, `gud` | another display for the desktop (below) |

`usb` (or `lsusb`) shows the devices as a tree. Each device is named by
its port path: `1-1.2` is port 2 of the hub on port 1 of bus 1. Each line
shows the device's ID, what it is, its speed and its driver. After the
arrow is what the device became:

```text
$ usb
usb1  xHCI Host Controller (root hub, 4 ports) [480 Mbit/s]
  1-1 0409:55aa  QEMU USB Hub (hub, 8 ports) [12 Mbit/s]
    1-1.1 0627:0001  QEMU USB Keyboard (HID) [12 Mbit/s; usbhid] -> event2
    1-1.2 0627:0001  QEMU USB Mouse (HID) [12 Mbit/s; usbhid] -> event4
    1-1.3 46f4:0001  QEMU USB HARDDRIVE (storage) [12 Mbit/s; usb-storage] -> sda
  1-2 0627:0001  QEMU USB Tablet (HID) [480 Mbit/s; usbhid] -> event1
  1-4 0525:a4a2  RNDIS/QEMU USB Network Device (communications) [12 Mbit/s; cdc_ether] -> usb0
usb2  xHCI Host Controller (root hub, 4 ports) [5 Gbit/s]
```

## Keyboards and mice

Any USB keyboard works, at the console and on the desktop (and so do
[Bluetooth](bluetooth.html) ones, once paired). Mice,
trackballs, touchpads, drawing tablets and touchscreens work on the
desktop ([Photon](desktop.html) and the classic desktop). Plug them in
at any time, directly, through a hub, or through a wireless receiver.

Most devices need only the standard HID driver. Lepton also has the
drivers for Apple keyboards, Magic Mouse and Magic Trackpad, Logitech's
Unifying and Bolt receivers, Microsoft, Lenovo, Cherry, ASUS and Elan
devices, Wacom tablets and multi-touch touchpads, and loads them when one
appears.

- **Mice**: the wheel scrolls, a tilting or second wheel scrolls sideways,
  and every button (side buttons too) reaches the program under the
  pointer.
- **Touchpads** move the pointer as you slide one finger. Click by
  pressing the pad (or its buttons). Tap-to-click and two-finger scrolling
  aren't supported yet.
- **Tablets and touchscreens** map their surface onto the display.
- **Keyboards**: every key, with the US layout. The volume keys set the
  volume (see [Sound](sound.html)).

`input` lists the input devices, what Lepton takes each for, and the USB
port it's on:

```text
$ input
event0   other     Power Button
event1   tablet    QEMU QEMU USB Tablet  (USB 1-2)
event2   keyboard  QEMU QEMU USB Keyboard  (USB 1-1.1)
```

At the text console a mouse does nothing (there is no console pointer).

**In UTM**, USB devices reach the VM one at a time. Turn on **Input → USB
Sharing** in the VM's settings, then click the **USB** icon in the
toolbar and choose a device. macOS keeps the hubs themselves, so a
device behind a hub on your desk shows up in the VM as if it were
plugged in directly. You rarely need to pass a keyboard or mouse: UTM
already gives the VM a keyboard and pointer that follow your Mac's. A
device you do pass belongs to the VM until you take it back, so keep
another one for the Mac. Hubs show up as hubs on real hardware and in QEMU
(`mix lepton.qemu` plugs its keyboard into a virtual hub).

## Displays

[Photon](desktop.html) (and the classic desktop) uses every display the
kernel has a framebuffer for (`/dev/fb0`, `/dev/fb1`, ...):

- **a second display of the VM.** In UTM, add a second **Display**
  device in the VM's settings and set its **Emulated Display Card** to
  `virtio-gpu-pci` (or `virtio-gpu-gl-pci`), not the default
  `virtio-ramfb`; UTM then opens a second window. With QEMU, run
  `mix lepton.qemu --displays 2`.

  A VM can have only one ramfb display (the firmware's framebuffer), and
  `virtio-ramfb` is a virtio GPU plus a ramfb. With two `virtio-ramfb`
  displays (or two `ramfb`), QEMU refuses to start the VM, before Lepton
  runs: *duplicate fw_cfg file name: vgaroms/vgabios-ramfb.bin* (or
  *etc/ramfb*). Keep the first display as it is and change the other
  one's card to `virtio-gpu-pci`.
- **a USB display adapter** (passed to the VM like any USB device):
  adapters with DisplayLink's USB 2.0 chips (DL-120, DL-160, DL-165,
  DL-195) through the `udl` driver, and Generic USB Display gadgets (a
  Raspberry Pi acting as a monitor, for example) through `gud`.

Displays plugged in while the desktop runs join it within two seconds,
and a display that goes away leaves it.

```sh
photon display           # the displays and how they're arranged
photon display extend    # one desktop across them, side by side (the default)
photon display mirror    # the same picture on every display
```

**Extended** (the default): the displays sit left to right. The first
(`/dev/fb0`, where the console was) is the primary display, and the next
one continues to its right. Move the pointer off the right edge, or drag
a window there, to reach the next display. New windows open on the
primary display, and maximizing fills the display the window's title bar
is on. The classic desktop's taskbar and Start menu stay on the primary
display. The desktop is as tall as the primary display. A taller display
shows black below that, and a shorter one shows only the top part.

**The pointer.** A mouse moves across all the displays. The VM's own
pointer (UTM's and QEMU's tablet) belongs to one display. UTM has one,
for the first display. `mix lepton.qemu --displays 2` gives each window
its own. To move a window from the keyboard, press **Alt+Shift+Right**
(or **Left**): the focused window moves to the next (or previous)
display.

**Mirrored**: every display shows the primary display's picture, scaled
to fit and centred, with black bars where the shapes differ.

### HDMI on a USB-C hub or dock

An HDMI port on a USB-C hub is one of two kinds, and they behave
differently:

- **DisplayPort Alternate Mode**, used by most USB-C hubs with HDMI. The
  picture comes from the computer's own graphics, carried on spare wires
  of the USB-C cable; it isn't a USB device. On a Mac, macOS drives that
  monitor and the VM can't take it over. Instead, drag UTM's window (or
  the VM's second display window) onto that monitor and make it full
  screen.
- **DisplayLink** docks send the picture over USB, so the dock's display
  chip can be passed to the VM. Lepton drives DisplayLink's older USB 2.0
  chips (`udl`). Newer ones (the DL-3000, DL-5000 and DL-6000 series in
  most USB 3 docks) need DisplayLink's closed-source driver, which Lepton
  doesn't have.

<!-- commands: usb input -->
