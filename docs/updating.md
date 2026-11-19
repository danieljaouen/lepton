---
title: Updating Lepton
order: 1
summary: Update an installed Lepton to the latest ISO, in UTM or QEMU, keeping your files, apps, accounts and settings.
---

# Updating Lepton

A new release of Lepton is a new ISO. Updating to it replaces Lepton
itself and keeps everything you made: your files, apps (Firefox),
accounts, packages, services, Wi-Fi networks, Bluetooth pairings and
settings.

This works because an installed Lepton has two partitions (see
[Install to a disk](getting-started.html#install-to-a-disk)):

| Partition | What it holds | On an update |
|---|---|---|
| `LEPTON-OS` | GRUB, the kernel and the initramfs: Lepton itself | replaced |
| `LEPTON-DATA` | `/home`, `/root`, `/var/lib/lepton` | kept, untouched |

The live ISO keeps nothing between starts, so there is nothing to update:
just start the new ISO.

## Before you start

1. **Shut down** with `sudo poweroff`, so that everything is saved.
2. In UTM you can also take a copy of the VM first, to go back to if you
   want: right-click it in UTM's list → **Clone**.

## Get the latest ISO

On your Mac, download it from the [home page](../#download) or the
[release page](https://github.com/danieljaouen/lepton.iso/releases/latest),
or in Terminal:

```sh
curl -LO https://github.com/danieljaouen/lepton.iso/releases/latest/download/lepton.iso
shasum -a 256 lepton.iso      # the same as the SHA-256 on trylepton.app
```

Keep it somewhere it can stay, such as `~/Documents/Lepton`: UTM uses the
file where it is.

## Update in UTM

1. **Choose the new ISO.** With the VM stopped, select it in UTM's list
   and click **Edit** (the sliders button). Under **Drives**, select the
   CD/DVD drive (**USB Drive** or **CD/DVD** under "Removable"), click
   **Browse…** next to its image, choose the new `lepton.iso` and click
   **Save**. (If you cleared the drive after installing, it's still there,
   empty: give it the ISO the same way.)
2. **Start the VM.** It may start the ISO or the Lepton on your disk;
   either is fine, because Lepton boots into memory and the ISO uses your
   disk's accounts and files while it runs. Log in with your own user
   name and password.
3. **Update:**

   ```sh
   sudo lepton-install
   ```

   It finds the new ISO and your installed Lepton, says which build you
   have and which you're getting, and replaces `LEPTON-OS`:

   ```text
   Upgrading Lepton on /dev/vda (build a1b2c3d4e5f6 -> 0f9e8d7c6b5a); your data partition is not touched
   ...
   Lepton on /dev/vda is upgraded (build a1b2c3d4e5f6 -> 0f9e8d7c6b5a).
   Your files, apps, accounts and settings were kept.
   ```

   A build is an identifier of the kernel and initramfs: different
   builds, different releases.
4. **Remove the ISO**: `sudo poweroff`, then in the VM's settings click
   **Clear** on the CD/DVD drive (or **CD/DVD → Eject** in the VM
   window's toolbar). Start the VM.

Log in as usual: you're on the new release.

## Update from inside Lepton

Without changing the VM's settings at all, Lepton can download the ISO
and update itself. It runs from memory, so it can replace its own
partition while it runs:

```sh
curl -o lepton.iso https://github.com/danieljaouen/lepton.iso/releases/latest/download/lepton.iso
sha256sum lepton.iso                  # the same as the SHA-256 on trylepton.app
sudo lepton-install --iso lepton.iso
sudo reboot
rm lepton.iso                         # after the restart: it's no longer needed
```

The download is about 130 MB and is held in memory while it arrives, so
give the VM 2 GB or more. This works the same way on any machine,
including QEMU.

## Update in QEMU

With the source tree, `mix lepton.qemu --disk disk.qcow2` boots the new
`out/lepton.iso` with your disk attached: log in and run `sudo
lepton-install`, then boot the disk alone with `mix lepton.qemu --no-cd
--disk disk.qcow2`. With plain QEMU, add the ISO as `-cdrom lepton.iso`
next to your disk, and leave it out again afterwards.

## If something goes wrong

- **"Lepton isn't installed on /dev/vda"**: the VM has no installed
  Lepton (you've been running the live ISO). Install it instead: see
  [Install to a disk](getting-started.html#install-to-a-disk).
- **"this release (…) doesn't fit in /dev/vda's OS partition"**: disks
  installed before `LEPTON-OS` existed have a smaller (200 MiB) partition
  in its place. Nothing was written: your installed Lepton still starts
  as before. Copy your files off (to a USB drive, say, or with `git
  push`), then install again from scratch with the new ISO.
- **You want to start over instead**: start the ISO, choose **live: leave
  installed disks alone** in the boot menu (it shows for three seconds as
  the VM starts) and run `sudo lepton-install --erase`. This erases the
  disk.
- **The VM still starts the old release**: the update didn't finish, or
  the VM is starting an old ISO that is still attached. Attach the new
  ISO and run `sudo lepton-install` again.

<!-- commands: lepton-install -->
