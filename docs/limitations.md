---
title: Limitations
order: 19
section: start
summary: What Lepton doesn't do yet.
---

# Limitations

> **Don't use Lepton where several people share one machine, or where
> anyone you don't trust can log in.** Lepton's userland is one Erlang VM
> running as root. Accounts and `sudo` are enforced by Lepton's commands,
> not by the kernel: anyone with a shell (at the console, through `ssh`,
> or a native program through `lepton`) can run `iex` or `elixir` and do
> anything root can, including reading every user's files and password
> hashes. Use separate accounts to keep your own files tidy, not to keep
> people apart. See [Users and sudo](users.html).

- The live ISO keeps everything in RAM. An installed system persists
  `/root` and `/var/lib/lepton` only; changes elsewhere (for example
  `/etc`) reset at boot.
- Bluetooth needs a USB adapter (a Mac's built-in Bluetooth stays with
  macOS); no headset microphones, file transfer or phones (see
  [Bluetooth](bluetooth.html)).
- Sound: no recording, and Lepton's own sounds (`beep`, `play`) don't
  mix with Firefox's (see [Sound](sound.html)).
- Touchpads: tap-to-click and two-finger scrolling work; no tap-and-drag,
  pinch or swipe gestures, and no palm rejection.
- USB display adapters: DisplayLink's USB 2.0 chips and Generic USB
  Display gadgets only; newer DisplayLink docks need a closed-source
  driver. A USB-C hub's HDMI port (DisplayPort Alternate Mode) belongs to
  the Mac, not the VM. See [USB, hubs and displays](usb.html).
- Wi-Fi needs a supported adapter: virtual machines have no wireless
  hardware (pass a USB adapter through). WPA2 and WPA2/WPA3 networks
  work; WPA3-only and enterprise (802.1X) networks don't.
- [Users and sudo](users.html) are enforced by Lepton's commands, not the
  kernel: everything runs in one Erlang VM as root, so `iex` and
  `elixir` can bypass them (see the warning above). Services all run as
  root.
- Services are simple ones only: no dependencies (`After=`,
  `Requires=`), timers, socket activation or resource limits.
- git: no three-way merge (pulls fast-forward only) and no rebase.
- SSH: keys only (no password logins, in or out), no passphrase-protected
  keys, no `ssh-agent`, port forwarding from Lepton's `ssh`, or `scp`/`sftp`
  commands on Lepton (rsync and sshfs work; from other computers, sftp,
  scp and sshfs reach Lepton's `sshd`).
- sshfs: no hard links or device files on the mount; a slow connection
  can hold up other file operations while it answers.
- Printing: network IPP printers that take PDF (or JPEG); no USB
  printers, raster-only printers or sharing.
- Proxies carry TCP only: NTP (UDP) goes directly. HTTPS proxies (TLS to
  the proxy itself) and PAC files aren't supported.
- rsync: protocol 27; no hard links (`-H`), relative paths (`-R`),
  owners and groups, or daemon mode, and Lepton's own transfers aren't
  compressed.
- `le` is a Spacemacs work-alike, not Emacs: it doesn't *evaluate* Elisp,
  so layers and packages aren't loaded. Unsupported bindings are
  reported.
- Packages that rely on Mix-specific features (compile-time config,
  application callbacks, NIFs) are not supported.
- Native ELF programs can run through a port (standard input and output
  only, no terminal). For the ones that start others through a shell
  (Mix's rebar3, PostgreSQL's `initdb`), `/bin/sh` is busybox's; at
  Lepton's prompt the shell is always `lsh`.
- [Claude Code](claude-code.html) runs its commands in Alpine's bash, and
  Lepton's own commands through `lepton COMMAND`, without a terminal; it
  gets a terminal of its own through `script`.
- [Virtual machines](virtual-machines.html) are arm64 only, headless (no
  display), and need nested virtualization (an M3 or later Mac) for full
  speed.
- `mix` can't build dependencies that compile C code (NIFs with a
  Makefile, like `bcrypt_elixir`): Lepton has no C compiler. Use
  pure-Elixir ones (`pbkdf2_elixir`), and `iex -S mix` isn't available.
- The Linux framebuffer console approximates 256-colour themes; a serial
  console in an xterm-compatible terminal renders them fully.

The graphical desktop, [Photon](desktop.html), runs terminal windows and
Wayland programs that draw with shared memory; see its guide for what it
doesn't do yet. The web browser is [Firefox](apps.html), installed on
demand; Lepton's own `www` is text-only.
