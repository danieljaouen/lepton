---
title: Limitations
order: 11
summary: What Lepton doesn't do yet.
---

# Limitations

- The live ISO keeps everything in RAM. An installed system persists
  `/root` and `/var/lib/lepton` only; changes elsewhere (for example
  `/etc`) reset at boot.
- Wi-Fi credentials can be saved but not used: the kernel has no Wi-Fi
  support and the virtual machines have no wireless hardware.
- Single user (`root`), with no permissions model beyond the kernel's.
- Services are simple ones only: no dependencies (`After=`,
  `Requires=`), timers, socket activation or resource limits.
- git: no three-way merge (pulls fast-forward only), no rebase and no SSH
  transport (HTTPS only).
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
