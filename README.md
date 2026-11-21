# Lepton OS

A Unix-like operating system for aarch64 whose entire userland (init, drivers
loading, networking, terminals, shell, coreutils, editor, multiplexer, git,
GitHub CLI, test runner) is written in Elixir and runs on the BEAM as PID 1.
It boots from a UEFI ISO in UTM or QEMU and is configured by **your dotfiles**:
Spacemacs keybindings, tmux key tables, git aliases, zsh aliases and the
starship prompt are read from the files themselves, not re-typed.

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Elixir (this repo)                                                  │
 │   lsh · coreutils · le (Spacemacs) · tmux · git · gh · www · svc     │
 │   TTY/line discipline · VT emulator · netlink + DHCP · init (PID 1)  │
 ├──────────────────────────────────────────────────────────────────────┤
 │  Erlang/OTP 29 runtime (ERTS, kernel, stdlib, ssl, crypto, inets)    │
 ├──────────────────────────────────────────────────────────────────────┤
 │  Linux 6.18 kernel (Alpine virt) · glibc · GRUB (UEFI)               │
 └──────────────────────────────────────────────────────────────────────┘
```

## What is Elixir and what is not

Everything that defines how the system *behaves* is Elixir. Below it sits
pre-built, unmodified substrate that is downloaded at build time
(`LeptonBuild.Sources`):

| Layer | Source | Why it is not Elixir |
|---|---|---|
| Linux kernel + modules + Wi-Fi firmware | Alpine `linux-lts` (v3.24), only the modules Lepton uses | the BEAM needs a kernel |
| `wpa_supplicant` (+ `hostapd` for the self-tests) | Alpine (musl, in `/usr/lib/musl`) | WPA authentication for Wi-Fi |
| Firefox and its libraries (GTK, fonts) | Alpine, downloaded when first used (`Lepton.Apps`, `Lepton.Alpine`) | a complete web browser |
| ERTS / OTP 29.1.2 | Hex.pm prebuilt for arm64 | "Erlang, and so on down the line" |
| glibc, libstdc++, zlib, libtinfo, libcrypto | Ubuntu 24.04 arm64 | ERTS links against them |
| GRUB EFI | Debian `grub-efi-arm64-unsigned` | firmware → kernel loader |
| CA certificates | Alpine | TLS trust roots |
| busybox (static) | Alpine | **syscall shim only**: `mount(2)`, `finit_module(2)` and termios `ioctl(2)`, which ERTS cannot issue. It is never exposed as a command (`Lepton.Sys`). |

The build tooling is Elixir too: the cpio (initramfs) writer, FAT12 and
ISO 9660 / Rock Ridge / El Torito writers, ELF dependency resolver and arm64
zboot unpacker live in `lib/lepton_build`.

## Deliverables

1. **Source**: `lib/lepton/**` (the OS), `lib/lepton_build/**` and
   `lib/mix/tasks/**` (image build tooling), `rootfs/` (files placed in
   `/etc`).
2. **Test suite**: `test/*_test.exs` (ExUnit). Run it *inside the OS* with
   `lepton-test`, on your Mac with `mix test`, or boot-and-test headlessly
   with `mix lepton.qemu --test`.
3. **ISO**: `out/lepton.iso` (UEFI, aarch64), built with `mix lepton.iso`.

## Download

A prebuilt ISO is published at
[danieljaouen/lepton.iso releases](https://github.com/danieljaouen/lepton.iso/releases)
([direct download](https://github.com/danieljaouen/lepton.iso/releases/latest/download/lepton.iso)),
and the project site is <https://trylepton.app/>.

## Documentation

The user documentation is at **<https://trylepton.app/docs/>**:

- [Getting started](https://trylepton.app/docs/getting-started.html):
  download, UTM and QEMU, installing to a disk, shutting down
- Guides: [the shell](https://trylepton.app/docs/shell.html),
  [the editor](https://trylepton.app/docs/editor.html),
  [tmux](https://trylepton.app/docs/tmux.html),
  [git and GitHub](https://trylepton.app/docs/git.html),
  [SSH](https://trylepton.app/docs/ssh.html),
  [services](https://trylepton.app/docs/services.html),
  [packages](https://trylepton.app/docs/packages.html),
  [networking](https://trylepton.app/docs/networking.html),
  [system](https://trylepton.app/docs/system.html),
  [the desktop](https://trylepton.app/docs/desktop.html),
  [Firefox and apps](https://trylepton.app/docs/apps.html),
  [your dotfiles](https://trylepton.app/docs/dotfiles.html) and
  [limitations](https://trylepton.app/docs/limitations.html)
- Reference: [every command](https://trylepton.app/docs/commands.html),
  [manual pages](https://trylepton.app/docs/man.html),
  [key bindings](https://trylepton.app/docs/keybindings.html) and
  [the tutorial](https://trylepton.app/docs/tutorial.html)

**How the docs stay current.** The guides are `docs/*.md` in this
repository, one per topic. The reference pages are generated from the
code: the command registry (every `defcmd`'s summary, usage and aliases),
`Lepton.Tutorial.lessons/1`, and the output of `keys`, `bindkey` and
`alias` for the dotfiles the ISO is built with. A guide can embed
`<!-- commands: ip ping -->` to get a table of those commands from the
registry. The manual pages are `man/*.md`, one per command: `man` shows
them inside Lepton (`Lepton.Man` compiles them in, adding NAME and
SYNOPSIS from the registry), and the docs publish each as
`man-NAME.html`.

- `mix lepton.docs` writes `docs/` in the site checkout (see
  [Repositories](#repositories); preview it locally); `--check` only
  validates.
- `mix lepton.publish` regenerates and publishes the docs with every
  release, so they always describe the downloadable ISO. It publishes
  documentation-only changes too, even when the ISO is unchanged.
- `mix test` fails if a page has a broken link, a guide names a command
  that doesn't exist, a guide isn't linked, a command has no summary
  or usage line, or a command or builtin has no manual page.

So a user-facing change means: update the code (with `usage:` on any new
`defcmd`), its manual page in `man/`, the relevant `docs/*.md` guide, run `mix test`, then
publish.

## Quick start

Requirements on the build machine: the Elixir and OTP in `versions.toml`
(the image ships that OTP, and compiled `.beam` files must match; the build
refuses others), `tar`, and network access for the first build. QEMU
(`brew install qemu`) is optional, for testing.

```sh
mix lepton.iso                 # -> out/lepton.iso (dotfiles from ~/.dotfiles, if any)
mix lepton.iso --dotfiles PATH # or set LEPTON_DOTFILES
mix lepton.qemu                # boot in a QEMU window (UTM-equivalent machine)
mix lepton.qemu --test         # headless boot, run lepton-test, report
mix lepton.qemu --run "uname -a" --run "ip addr"
mix lepton.qemu --ssh-port 2222 # forward localhost:2222 to the VM's sshd (start it inside)
mix lepton.shell               # run the userland in this terminal, no VM
mix lepton.docs                # build the documentation into the site's docs/
mix lepton.site.tags           # put the site tags (lib/lepton_build/site_head.html) on every page
mix lepton.publish             # build + publish the ISO, the docs and the site's checksum
mix lepton.versions            # versions.toml (kernel, OTP, Elixir) against the newest available
mix lepton.official add ...    # sign an official app update (docs: packages)
mix test                       # host-side test run
```

## Architecture

- **Boot** (`Lepton.Init`): GRUB starts Linux with `rdinit=/init`, a symlink
  to `erlexec`. The kernel command line carries the ERTS environment and
  flags, and ERTS calls `Lepton.Init.main/0` as PID 1. Init mounts
  `/proc /sys /dev /dev/pts /run`, quiets printk, sets the hostname, loads
  drivers through `Lepton.Kmod` (which resolves `modules.dep` itself), starts
  the application, configures the network in the background, and opens a
  login session on each console.
- **Users** (`Lepton.Users`): accounts (`passwd`/`group`/`shadow` with
  PBKDF2 hashes) live in `/var/lib/lepton`; the installer creates one, and
  consoles then log in. Identity is a field of each process's context, so
  `root: true` commands, file-write checks and `sudo` (password, 5-minute
  timestamp per terminal) apply to it. This is enforced by Lepton's
  commands, not the kernel: the userland is one Erlang VM running as root.
- **Processes** (`Lepton.Proc`): every program is a BEAM process with a
  Unix-style PID, parent, tty and state. `C-c` kills the foreground job,
  `C-z` suspends it (`:erlang.suspend_process`), and `fg`/`bg`/`jobs` work.
- **Services** (`Lepton.Services`): a supervised manager that runs each
  service's `ExecStart` in its own process tree and watches it. It
  applies the restart policy and start limit, and collects output through
  an I/O server into per-service logs. `Lepton.Init` starts enabled
  services after the data partition is mounted, and `poweroff`/`reboot`
  stop them first.
- **I/O**: TTYs (`Lepton.TTY`) and pipes (`Lepton.Pipe`) are Erlang I/O
  servers, so `IO.puts` works anywhere. Pipes apply back-pressure, and
  writing to a closed pipe exits the writer (SIGPIPE). The TTY has a cooked
  line discipline and a raw key mode that decodes input to Emacs `kbd` key
  names.
- **Multiplexer**: each session is a supervised process that outlives its
  client. Panes are TTYs whose output feeds a VT100/xterm emulator
  (`Lepton.Screen`, with scrollback and the alternate screen). The client
  composes panes, borders and the status line, and redraws only changed
  rows.
- **Networking**: `Lepton.Net.Netlink` sends rtnetlink messages over
  `:socket` (AF_NETLINK) to bring links up and add addresses and routes.
  `Lepton.Net.DHCP` is a DHCPv4 client. DNS uses Erlang's resolver, and TLS
  uses `:ssl` with the bundled CA roots. `Lepton.SSH` is an SSH client on
  OTP's `:ssh`, with its own key callback for keys, known hosts (GitHub's
  built in) and `~/.ssh/config`. `ssh` and git's SSH transport use it.
  `Lepton.SSHD` is the server, on OTP's SSH daemon: public keys only,
  checked against each account's `~/.ssh/authorized_keys`; a session with
  a terminal gets a `Lepton.TTY` whose backend is the channel. It ships
  as the disabled `sshd` service.
- **Desktop** (`Lepton.Photon`): a Wayland compositor. Clients connect to a
  Unix socket and speak the wire protocol (`Lepton.Wayland`: the core
  interfaces and `xdg-shell`). Shared-memory buffers arrive as file
  descriptors over `SCM_RIGHTS` (`:socket`) and are read through
  `/proc/self/fd`. Photon composes only damaged rectangles (background,
  decorated windows, pointer) and `pwrite`s them to `/dev/fb0`. Input comes
  from evdev devices read as files. Terminal windows
  (`Lepton.Photon.Term`) are Wayland clients that run `lsh` on a TTY and
  draw `Lepton.Screen` with the Terminus PSF font. Descriptors received
  from clients are closed by `Lepton.FD`, a 700-byte NIF whose ELF and
  aarch64 code Lepton writes itself (OTP has no way to close a descriptor
  it didn't open). Native apps run as the logged-in user through
  `Lepton.RunAs`, a 340-byte static executable Lepton also writes itself
  (setgroups, setgid, setuid, execve). Window managers
  (`Lepton.Photon.WM`) decide decorations and the desktop around the
  windows: Photon's own, or the Windows 95-style classic desktop
  (`classic`: taskbar, Start menu, desktop icons).

## Repositories

- This repository. Clone it with `git clone --recursive
  https://github.com/danieljaouen/lepton` to get the website as well.
- **Dotfiles** are not part of it. `mix lepton.iso` installs
  `$LEPTON_DOTFILES` or `~/.dotfiles` (the published ISO uses
  [danieljaouen/dotfiles](https://github.com/danieljaouen/dotfiles)), or
  uses Lepton's defaults when there is none. Pass `--dotfiles PATH` to
  choose another.
- **Website**: `site/` is a submodule of
  [danieljaouen.github.io](https://github.com/danieljaouen/danieljaouen.github.io)
  over HTTPS, for reading. The tooling (`mix lepton.docs`, `lepton.site.tags`,
  `lepton.official`, `lepton.publish`) writes to the *site checkout*:
  `$LEPTON_SITE`, else an SSH clone at `../danieljaouen.github.io`
  (maintainers: `git clone git@github.com:danieljaouen/danieljaouen.github.io.git
  ../danieljaouen.github.io`), else `site/`. Whenever the site's `main`
  changes, from a push, `mix lepton.publish` or an edit on github.com, a
  workflow in the site repository moves this repository's `site/`
  submodule to the new commit and pushes it. Pull to pick that up.
- **ISO releases**: `../lepton.iso`, a clone of
  [danieljaouen/lepton.iso](https://github.com/danieljaouen/lepton.iso);
  the ISOs themselves are GitHub Release assets.

## Testing

`lepton-test` (inside the OS) compiles and runs the same `test/*_test.exs`
files that `mix test` runs on a Mac. Tags pick tests by environment:
`:native` needs the real system (PID 1, mounts, loaded drivers, installed
dotfiles); `:network` needs internet access (DHCP, DNS, and cloning
`octocat/Hello-World` from GitHub) and is enabled automatically when the
network is up; `:dotfiles` needs your dotfiles (on a Mac: `~/.dotfiles` or
`$LEPTON_DOTFILES`, in the `topics/` layout). Options: `--only TAG`,
`--include TAG`, `-v`, or file paths.

Current results: 282 tests, 0 failures inside the VM (run from the live
ISO; the 14 `:docs` tests, for the docs and site tags, are host-only), and
278 passing plus 18 excluded (native/network) on the host.

## Daily updates

`versions.toml` records the kernel (Alpine's `linux-lts`), OTP and Elixir
Lepton is built from. `tools/daily-update`, run at 09:00 by a LaunchAgent
on the build machine, checks them with `mix lepton.versions --check` and,
only when one is newer, has Claude Code upgrade, rebuild, fix, test, commit,
push and publish (the steps are in CLAUDE.md).

## Roadmap: GUI and web browser

The CLI layers were built so a graphical stack can sit on top of them:

1. **Display** (done): Photon writes pixels to `/dev/fb0` from Elixir,
   with the mode read from sysfs. Next: DRM dumb buffers and page flips,
   adding `DRM_IOCTL_*` calls to the syscall shim boundary in `Lepton.Sys`.
2. **Input** (done): `/dev/input/event*` is read as files and decoded
   into keys and pointer events (including the tablet UTM attaches).
3. **Compositor** (done): Photon, a Wayland compositor
   ([guide](https://trylepton.app/docs/desktop.html)), with terminal
   windows that reuse `Lepton.Screen`. Next: alpha blending, the
   clipboard, and native Wayland programs from Alpine.
4. **Text**: a bitmap font (Terminus, PSF) is done. Next: a TrueType
   rasterizer in Elixir.
5. **Browser** (done, natively): Firefox runs on Photon, installed on
   demand from Alpine's packages
   ([guide](https://trylepton.app/docs/apps.html)). Lepton's own `www`
   stays a text browser (HTTP(S), an HTML tokenizer, text layout and
   links).

## Credits

Lepton OS was designed and written by **Claude** (Anthropic's Claude Opus
5.5, an AI model), working in Claude Code at the direction of
[Daniel Jaouen](https://github.com/danieljaouen), whose dotfiles define how
it behaves. `credits` shows this inside the OS.

It stands on the shoulders of Linux, Erlang/OTP and ERTS, Elixir, Alpine
Linux (kernel packaging, busybox, CA bundle), Debian (the GRUB EFI build),
Ubuntu (glibc and runtime libraries), and Hex.pm (prebuilt OTP and the
package registry `lpm` uses).

## Repository layout

```
lib/lepton/            the operating system
  init.ex sys.ex kmod.ex          PID 1, syscall shim, module loader
  tty.ex tty/ keys.ex pipe.ex     terminals, key decoding, pipes
  proc.ex io.ex application.ex    process table, I/O helpers, sessions
  shell.ex shell/                 lsh: parser, expansion, executor, ZLE, prompt
  commands/                       coreutils, text, system, network, dev tools, desktop
  editor.ex editor/               le: evil engine, keymaps, render, magit, ex
  mux.ex mux/                     tmux: server, client, layout, copy mode, config
  git.ex git/ gh.ex               git + GitHub (HTTPS and SSH remotes)
  ssh.ex ssh/                     SSH client: keys, known hosts, ssh/ssh-keygen
  sshd.ex                         SSH server (keys only): sessions on a TTY or pipes, SFTP
  sshfs.ex fd.ex                  sshfs: a FUSE server over SFTP (the NIF mounts it)
  rsync.ex rsync/                 rsync (protocol 27): client, server, file list, delta, -z tokens
  net.ex browser.ex screen.ex     networking, text browser, VT emulator
  dotfiles.ex elisp.ex toml.ex    config readers
  install.ex install/             lepton-install: GPT, FAT16, ext2, persistence, upgrades
  wifi.ex                         Wi-Fi: saved networks, wpa_supplicant manager
  usb.ex                          USB: device tree (hubs), hotplug driver loading
  media.ex media/                 USB drives and SD cards: filesystem detection, automount, eject
  sound.ex sound/                 sound: ALSA in Elixir (ioctl), the volume, WAV files and tones
  bluetooth.ex dbus.ex dbus/      Bluetooth (BlueZ over D-Bus: devices, pairing agent, headphones); a D-Bus client
  users.ex                        accounts, login, sudo and permission checks
  setup.ex tutorial.ex            first-run setup (Wi-Fi prompt), tutorial
  pkg.ex official.ex              lpm, signed official updates
  services.ex power.ex            svc service manager, power button
  cron.ex                         cron: crontab syntax, crond (the cron service)
  ntp.ex time.ex tz.ex            ntpd (SNTP, GeoIP time zone), local time, TZif zone files
  proxy.ex                        proxies and chains (HTTP CONNECT, SOCKS4/5), the web forwarder
  vdagent.ex                      the SPICE guest agent: UTM's shared clipboard, and its mouse (to Photon)
  httpd.ex certs.ex                the web server (files, reverse proxy, WebSockets, TLS by SNI) and certificates (local CA, ACME)
  vault.ex vault/                 the password manager: the encrypted vault, its agent, `vault`, the Passwords window
  ipp.ex print.ex print/          printing: IPP, mDNS discovery, text to PDF, cupsd (IPP server on :631)
  photon.ex photon/ wayland/      Photon: Wayland compositor, displays, window managers, terminal windows, protocol
  apps.ex alpine.ex fd.ex         native apps (Firefox) from Alpine packages; the NIF: close, ioctl
  run_as.ex                       running native programs as the logged-in user
  man.ex pager.ex                 man (pages from man/), less, top
  selftest.ex                     lepton-test
lib/lepton_build/      image and docs build tooling (not shipped in the image)
lib/mix/tasks/         mix lepton.iso | qemu | shell | publish | official | docs
docs/                  the user guides (Markdown; published to trylepton.app/docs)
man/                   a manual page per command (Markdown; compiled into man, published with the docs)
rootfs/etc/            /etc files (lshrc, motd, hostname, lepton/services, ssh/ssh_known_hosts, ...)
rootfs/usr/share/      the Terminus console fonts Photon draws text with
test/                  ExUnit suite (host + in-OS)
site/                  the website and generated docs (submodule: danieljaouen.github.io, read-only HTTPS)
```
