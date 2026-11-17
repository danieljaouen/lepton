---
title: Limitations
order: 13
summary: What Lepton doesn't do yet.
---

# Limitations

- The live ISO keeps everything in RAM. An installed system persists
  `/root` and `/var/lib/lepton` only; changes elsewhere (for example
  `/etc`) reset at boot.
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

There's no graphical desktop or full web browser yet; see the
[roadmap](../#roadmap).
