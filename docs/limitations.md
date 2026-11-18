---
title: Limitations
order: 16
summary: What Lepton doesn't do yet.
---

# Limitations

- The live ISO keeps everything in RAM. An installed system persists
  `/root` and `/var/lib/lepton` only; changes elsewhere (for example
  `/etc`) reset at boot.
- USB display adapters: DisplayLink's USB 2.0 chips and Generic USB
  Display gadgets only; newer DisplayLink docks need a closed-source
  driver. A USB-C hub's HDMI port (DisplayPort Alternate Mode) belongs to
  the Mac, not the VM. See [USB, hubs and displays](usb.html).
- Wi-Fi needs a supported adapter: virtual machines have no wireless
  hardware (pass a USB adapter through). WPA2 and WPA2/WPA3 networks
  work; WPA3-only and enterprise (802.1X) networks don't.
- [Users and sudo](users.html) are enforced by Lepton's commands, not the
  kernel: everything runs in one Erlang VM as root, so `iex`, `elixir` and
  `mix` can bypass them. Services all run as root.
- Services are simple ones only: no dependencies (`After=`,
  `Requires=`), timers, socket activation or resource limits.
- git: no three-way merge (pulls fast-forward only) and no rebase.
- SSH: keys only (no password logins), no passphrase-protected keys, no
  `ssh-agent`, forwarding, `scp`/`sftp` or SSH server.
- `le` is a Spacemacs work-alike, not Emacs: it doesn't *evaluate* Elisp,
  so layers and packages aren't loaded. Unsupported bindings are
  reported.
- Packages that rely on Mix-specific features (compile-time config,
  application callbacks, NIFs) are not supported.
- Native ELF programs can run through a port (standard input and output
  only, no terminal).
- The Linux framebuffer console approximates 256-colour themes; a serial
  console in an xterm-compatible terminal renders them fully.

The graphical desktop, [Photon](desktop.html), runs terminal windows and
Wayland programs that draw with shared memory; see its guide for what it
doesn't do yet. The web browser is [Firefox](apps.html), installed on
demand; Lepton's own `www` is text-only.

Some pages make Firefox freeze and then crash. GitHub when you're signed
in is one of them. This is a known problem that isn't fixed yet.
