---
title: USB drives and SD cards
order: 14
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

**Filesystems**: FAT (FAT12, FAT16, FAT32: most sticks and SD cards),
exFAT (large SD cards), NTFS (Windows drives), ext2/3/4 (Linux drives) and
ISO 9660 (CD images written to a stick). FAT, exFAT and NTFS have no
owners or permissions, so every user can read and write them. A
filesystem the kernel won't write, such as an NTFS drive that Windows
left hibernated, is mounted read-only.

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
See [USB, hubs and displays](usb.html).

Lepton's own disk (where an installed Lepton keeps your files) is never
mounted under `/media`.

<!-- commands: lsblk eject mount -->
