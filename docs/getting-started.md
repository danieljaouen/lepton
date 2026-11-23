---
title: Getting started
order: 1
section: start
summary: Download the ISO, boot it in UTM or QEMU, install it to a disk and shut it down cleanly.
---

# Getting started

Lepton is a Unix-like operating system for ARM64 whose userland is written
in Elixir. It ships as one bootable ISO that works in UTM or QEMU on Apple
Silicon, either as a live system that runs from RAM or installed to a
virtual disk.

## Download

Download the latest ISO from
[the release page](https://github.com/danieljaouen/lepton.iso/releases/latest),
or directly:

```sh
curl -LO https://github.com/danieljaouen/lepton.iso/releases/latest/download/lepton.iso
shasum -a 256 lepton.iso      # compare with the SHA-256 on trylepton.app
```

It is a hybrid image: it boots when attached as a CD or as a disk.

## Run it in UTM

1. **Create a New Virtual Machine → Virtualize → Linux**.
2. **Boot ISO Image**: choose `lepton.iso`. Leave "Use Apple
   Virtualization" unchecked (the QEMU backend is the tested path).
3. Memory: 2048 MB or more; CPU: 2+ cores. Storage: any size (the live
   system runs from RAM and does not touch the disk).
4. Optional: **Devices → New → Serial**, to get a second login session in
   UTM's terminal window. That window speaks xterm, so 256 colours and
   Unicode look better there than on the framebuffer console, and
   full-screen programs follow its window size.
5. Leave **Sharing → Clipboard Sharing** on (the default): Lepton's
   clipboard and your Mac's are then one (`pbpaste`, Cmd-V); see
   [the clipboard](system.html#sharing-it-with-your-mac-utm).
6. Start the VM. GRUB boots the default entry after 3 seconds. Other
   entries give a verbose boot and a boot that runs the self-tests.

UTM's window shows the console with the default display card
(`virtio-ramfb`); no serial device is needed. Other cards, such as
`virtio-gpu-pci` and `ramfb`, work too.

You are logged in as `root` on the display console (`tty1`), on the
serial port (`ttyAMA0`) if present, and on `hvc0` under Apple
Virtualization. The network comes up by DHCP in the background.

## Run it with QEMU

```sh
qemu-system-aarch64 -M virt -accel hvf -cpu host -m 2048 \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -cdrom lepton.iso -nographic
```

Use `-accel tcg -cpu max` on hosts without Apple's hypervisor. From a
source checkout, `mix lepton.qemu` does the same.

## Install to a disk

The live ISO keeps everything in RAM. To keep your files, install it:

1. With the VM stopped, add a disk: **Drives → New → VirtIO** (or NVMe),
   4 GB or more.
2. Boot the ISO and run `lepton-install`. It asks which disk, asks you to
   confirm, and asks you to **create your user account**: a user name and
   a password. That account can run administrative commands with
   [sudo](users.html).
3. `poweroff`, then **CD/DVD → Clear** to eject the ISO, and start the VM.
4. Log in with your user name and password.

For an unattended install, `echo PASSWORD | lepton-install -y -u NAME
--password-stdin /dev/vda` skips every question.

### Alongside other systems

A disk that already has partitions (macOS's, say, with room made for
Lepton) keeps them. `lepton-install` lists what is on it and offers the
places where Lepton fits without touching anything else:

```text
/dev/vda (64 GiB) has:
  /dev/vda1    200 MiB  EFI System Partition (vfat)
  /dev/vda2     40 GiB  Macintosh HD (apfs)
  /dev/vda3     24 GiB  empty
Where should Lepton go?
  1) /dev/vda3: empty, 24 GiB (recommended)
  2) erase the whole disk (everything on it is lost)
```

- **An empty partition**: one with no filesystem, or with an empty one
  (an "MS-DOS (FAT)" or exFAT partition you made for Lepton in Disk
  Utility, with nothing in it yet). The empty one is the default.
- **Free space** that isn't in any partition, 1 GiB or more.
- **Erase the whole disk**, always last, and only when you choose it.

Lepton's two partitions are made in the place you pick. The other
partitions keep their numbers and contents; the installer never offers
EFI, Apple (APFS, HFS+, recovery) or Microsoft system partitions, or one
with files in it. To pick the place yourself, name the partition:
`lepton-install /dev/vda3`. With `-y`, Lepton goes into the first place
offered, and a disk with other partitions but no room is left alone
(unless you add `--erase`).

This is for a VM's disk, or an external drive you pass to the VM. A Mac
starts only macOS from its own internal disk.

The installer writes a GPT partition table and two partitions, all from
Elixir:

- **`LEPTON-OS`** (512 MiB, FAT16, the EFI system partition): Lepton
  itself, meaning GRUB, the kernel and the initramfs. The installed
  system boots into RAM from it.
- **`LEPTON-DATA`** (ext2, the rest of the disk): everything you make.
  `/home` (your files), `/root` and `/var/lib/lepton` (accounts, apps
  such as Firefox, packages, services, Wi-Fi networks, Bluetooth
  pairings, settings, logs) live here. Your home starts with the image's
  dotfiles.

With QEMU: `qemu-img create -f qcow2 disk.qcow2 8G`, then
`mix lepton.qemu --disk disk.qcow2` to install and
`mix lepton.qemu --no-cd --disk disk.qcow2` to boot the installed system
(add `--login NAME:PASSWORD` with `--run` to script it).

## Upgrade to a new release

Because Lepton and your data are on separate partitions, a new release
replaces only Lepton. [Updating Lepton](updating.html) has the steps in
full, for UTM, QEMU and from inside Lepton; in short:

1. Download the new ISO.
2. In UTM, choose it for the VM's **CD/DVD** drive and start the VM.
   Whether the VM starts the ISO or your installed Lepton doesn't matter:
   either way, log in with your own account and run `sudo lepton-install`.
   It finds the ISO and the Lepton on your disk, and upgrades it.
3. `sudo poweroff`, eject the ISO (**CD/DVD → Clear**) and start the VM.

Your files, apps, accounts and settings are all still there: the upgrade
writes the `LEPTON-OS` partition and nothing else. (The ISO uses your
disk's accounts and files while it runs, which is why it asks for your
password.)

You can also upgrade from the installed system itself, without booting
the ISO: download it, then run `sudo lepton-install --iso lepton.iso` and
`sudo reboot`. Lepton runs from memory, so it can replace itself while
running; the new release starts at the next boot.

| Command | What it does |
|---|---|
| `lepton-install` | install (a disk without Lepton), or ask whether to upgrade or erase |
| `lepton-install --upgrade` | upgrade without asking (`-y` upgrades too) |
| `lepton-install --erase` | erase the disk and install from scratch (asks you to confirm) |
| `lepton-install /dev/vda3` | install into that partition, leaving the disk's other partitions alone |
| boot menu: **live: leave installed disks alone** | start the ISO without your disk's files, accounts and settings (to erase that disk, say) |
| `lepton-install --iso FILE` | install or upgrade from a downloaded ISO file |

Started from an ISO that is using your disk, `lepton-install` can only
upgrade it; to erase the disk and start over, choose **live: leave
installed disks alone** in the ISO's boot menu (it shows for three
seconds as the VM starts) and run `lepton-install --erase`.

The installer says which release you had and which you have now, as
builds: an identifier of the kernel and initramfs (a disk installed
before builds were recorded says so). Disks installed before the
`LEPTON-OS` partition existed have a 200 MiB "EFI System" partition in
its place. They upgrade the same way for as long as a release fits; one
that doesn't is refused without writing anything, and the installer says
so.

With QEMU, `mix lepton.qemu --disk disk.qcow2` boots the new ISO with
your disk attached, for `lepton-install`.

<!-- commands: lepton-install -->

## Shut down

Type `sudo poweroff` (just `poweroff` on the live ISO, where you are
root), or use UTM's power button → **Request power down**.
Lepton hears the virtual power button, warns the consoles, stops running
services, flushes the data partition and remounts it read-only, so the
next start is a clean boot through GRUB. "Force shut down" and closing the
VM window pull the plug and can't be intercepted.

Logging out with `C-d` returns an installed system to its login prompt.
On the live ISO the console logs straight back in, with a reminder that
`poweroff` is the way to shut down.

<!-- commands: poweroff reboot -->

## First boot after installing

- **Tutorial.** Lepton offers an interactive tour once, on the first boot
  after installation. `lepton-tutorial` runs it any time; see
  [the tutorial](lepton-tutorial.html) for the lessons.
- **Wi-Fi.** On a machine with a Wi-Fi adapter, Lepton asks for a network
  at startup until one is saved (Enter skips). Virtual machines have no
  Wi-Fi hardware, so you won't see it there. See
  [Networking](networking.html#wi-fi).

## Where next

- [The shell](shell.html) and [the commands](commands.html)
- [Typing accents](accents.html): Alt+e e is é, Alt+u u is ü
- [Your dotfiles, applied](dotfiles.html) and the
  [key bindings](keybindings.html) they produce
- [Services](services.html) and [packages](packages.html)
