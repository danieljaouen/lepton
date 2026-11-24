---
title: USB drives and SD cards
order: 14
section: hardware
summary: Plug in a USB drive, stick or SD card and it's mounted under /media; eject it before you unplug it.
---

# USB drives and SD cards

Plug in a USB drive or stick, or insert an SD card (in a card slot or a
USB card reader), and Lepton mounts it within a second or two, under
`/media`. Its folder is named after the drive's label (`/media/CAMERA`),
or after the device (`/media/sdb1`) when it has none.

```sh
lsblk                     # disks, partitions, filesystems and mount points
ls /media/CAMERA          # use the files like any others
eject /media/CAMERA       # ...then unplug it
```

Another machine's files can be mounted too, over SSH: see
[sshfs](ssh.html#mounting-another-machine-sshfs).

To back up to a drive, [rsync](rsync.html) copies only what changed since
last time: `rsync -av ~/notes/ /media/BACKUP/notes/`. FAT and exFAT
drives keep times only to the nearest two seconds, so if unchanged files
are sent again each time, add `--size-only` (or `-c`, to compare
contents).

**Filesystems**: FAT (FAT12, FAT16, FAT32: most sticks and SD cards),
exFAT (large SD cards), NTFS (Windows drives), ext2/3/4 (Linux drives) and
ISO 9660 (CD images written to a stick). FAT, exFAT and NTFS have no
owners or permissions, so every user can read and write them. A
filesystem the kernel won't write, such as an NTFS drive that Windows
left hibernated, is mounted read-only. A Mac's own formats, APFS and
HFS+ (Mac OS Extended), aren't mounted: Linux can't read them here. To
use a drive with both your Mac and Lepton, format it as **exFAT** (in Disk
Utility, choose View → Show All Devices, select the drive itself rather
than its volume, then Erase: exFAT, GUID Partition Map; this erases it).
A drive that isn't mounted says why when it is plugged in: a notice on
the desktop, and a line in `/var/log/messages` (`lsblk` shows its
format too).

**Several partitions** on a drive are each mounted in their own folder.
A drive with no partition table, as many sticks and cards are, is
mounted whole.

**On the classic desktop**, each mounted drive gets an icon below the
others. Double-click it to open a terminal in the drive's folder.

## Eject before you unplug

Lepton writes to drives in the background, so pulling one out too soon
can lose what you just saved. `eject` writes everything out, unmounts the
drive and, for a USB drive, detaches it, so it's safe to remove. It
isn't mounted again until you plug it back in.

```sh
eject                 # the only drive that is mounted
eject /media/BACKUP   # by folder (or any folder inside it)
eject sdb             # by device: every partition of the drive
```

`eject` fails while a program has a file on the drive open; close it
first. A drive pulled out without ejecting is unmounted anyway, and its
folder disappears.

A drive you unmount by hand (`sudo umount /media/BACKUP`) also stays
unmounted until it's plugged in again. To mount one somewhere else, use
`sudo mount /dev/sdb1 /mnt/backup`.

## In UTM

Turn on **Input → USB Sharing** in the VM's settings, then click the
**USB** icon in the toolbar while the VM runs and pick the drive or card
reader. macOS lets go of it and Lepton mounts it. To give the drive back
to the Mac, eject it in Lepton first, then pick it again in the USB menu.
Eject it in the Finder first (without unplugging it), so macOS isn't
using it. See [USB, hubs and displays](usb.html).

**Fast USB SSDs** (a Samsung T7, most USB 3 SSDs) normally use UAS, a
protocol that doesn't survive UTM's USB passthrough: the drive drops out
at once and UTM says it was rejected by the host. In UTM (QEMU) Lepton
uses such drives with usb-storage instead, the protocol USB sticks use:
a little slower, but they work. Nothing changes on a real machine.

Lepton's own disk (where an installed Lepton keeps your files) is never
mounted under `/media`.

<!-- commands: lsblk eject mount -->
