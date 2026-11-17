---
title: Getting started
order: 1
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
5. Start the VM. GRUB boots the default entry after 3 seconds. Other
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

The installer writes a GPT partition table, a FAT16 EFI system partition
(GRUB, kernel and initramfs) and an ext2 data partition named
`LEPTON-DATA`, all from Elixir. The installed system still boots into
RAM, but `/home` (your files), `/root` and `/var/lib/lepton` (accounts,
packages, services, logs, settings) live on the data partition. Your home
starts with the image's dotfiles.

With QEMU: `qemu-img create -f qcow2 disk.qcow2 8G`, then
`mix lepton.qemu --disk disk.qcow2` to install and
`mix lepton.qemu --no-cd --disk disk.qcow2` to boot the installed system
(add `--login NAME:PASSWORD` with `--run` to script it).

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
  [the tutorial](tutorial.html) for the lessons.
- **Wi-Fi.** On a machine with a Wi-Fi adapter, Lepton asks for a network
  at startup until one is saved (Enter skips). Virtual machines have no
  Wi-Fi hardware, so you won't see it there. See
  [Networking](networking.html#wi-fi).

## Where next

- [The shell](shell.html) and [the commands](commands.html)
- [Your dotfiles, applied](dotfiles.html) and the
  [key bindings](keybindings.html) they produce
- [Services](services.html) and [packages](packages.html)
