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
  [your dotfiles](https://trylepton.app/docs/dotfiles.html) and
  [limitations](https://trylepton.app/docs/limitations.html)
- Reference: [every command](https://trylepton.app/docs/commands.html),
  [key bindings](https://trylepton.app/docs/keybindings.html) and
  [the tutorial](https://trylepton.app/docs/tutorial.html)

**How the docs stay current.** The guides are `docs/*.md` in this
repository, one per topic. The reference pages are generated from the
code: the command registry (every `defcmd`'s summary, usage and aliases),
`Lepton.Tutorial.lessons/1`, and the output of `keys`, `bindkey` and
`alias` for the dotfiles the ISO is built with. A guide can embed
`<!-- commands: ip ping -->` to get a table of those commands from the
registry.

- `mix lepton.docs` writes `docs/` in the site checkout (see
  [Repositories](#repositories); preview it locally); `--check` only
  validates.
- `mix lepton.publish` regenerates and publishes the docs with every
  release, so they always describe the downloadable ISO. It publishes
  documentation-only changes too, even when the ISO is unchanged.
- `mix test` fails if a page has a broken link, a guide names a command
  that doesn't exist, a guide isn't linked, or a command has no summary
  or usage line.

So a user-facing change means: update the code (with `usage:` on any new
`defcmd`), update the relevant `docs/*.md` guide, run `mix test`, then
publish.

## Quick start

Requirements on the build machine: Elixir 1.18+ on **OTP 29** (the image ships
OTP 29.1.2, and compiled `.beam` files must match), `tar`, and network access
for the first build. QEMU (`brew install qemu`) is optional, for testing.

```sh
mix lepton.iso                 # -> out/lepton.iso (dotfiles from ~/.dotfiles, if any)
mix lepton.iso --dotfiles PATH # or set LEPTON_DOTFILES
mix lepton.qemu                # boot in a QEMU window (UTM-equivalent machine)
mix lepton.qemu --test         # headless boot, run lepton-test, report
mix lepton.qemu --run "uname -a" --run "ip addr"
mix lepton.shell               # run the userland in this terminal, no VM
mix lepton.docs                # build the documentation into the site's docs/
mix lepton.site.tags           # put the site tags (lib/lepton_build/site_head.html) on every page
mix lepton.publish             # build + publish the ISO, the docs and the site's checksum
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

Current results: 120 tests, 0 failures inside the VM (run from the live
ISO; the 13 `:docs` tests, for the docs and site tags, are host-only), and
123 passing plus 10 excluded (native/network) on the host.

## Roadmap: GUI and web browser

The CLI layers were built so a graphical stack can sit on top of them:

1. **Display**: the kernel already provides a DRM/fbdev framebuffer
   (`virtio-gpu` at boot, or `simpledrm` when the machine has no virtio
   GPU). Phase 1 writes pixels to `/dev/fb0` from Elixir (mode queried via
   sysfs). Phase 2 uses DRM dumb
   buffers and page flips, adding `DRM_IOCTL_*` calls to the syscall shim
   boundary in `Lepton.Sys`.
2. **Input**: `evdev` is loaded, so `/dev/input/event*` can be read as files
   and decoded into the same key vocabulary used today, plus pointer events
   (the tablet device UTM attaches).
3. **Compositor / window system**: a supervised `Lepton.Display` process
   owning the framebuffer, with windows as processes that send damage
   rectangles (the multiplexer's dirty-row model, generalized to pixels).
   Terminal windows reuse `Lepton.Screen`.
4. **Text**: a bitmap font first (PSF, the same format the console uses),
   then a TrueType rasterizer in Elixir.
5. **Browser**: `www` is the first slice. It already has HTTP(S) fetching,
   an HTML tokenizer and a text layout pass with link navigation. Next come
   a CSS parser and cascade, a box-model layout engine targeting the
   compositor, and images (PNG decoding via `:zlib`). JavaScript is a much
   later milestone.

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
  commands/                       coreutils, text, system, network, dev tools
  editor.ex editor/               le: evil engine, keymaps, render, magit, ex
  mux.ex mux/                     tmux: server, client, layout, copy mode, config
  git.ex git/ gh.ex               git + GitHub (HTTPS and SSH remotes)
  ssh.ex ssh/                     SSH client: keys, known hosts, ssh/ssh-keygen
  net.ex browser.ex screen.ex     networking, text browser, VT emulator
  dotfiles.ex elisp.ex toml.ex    config readers
  install.ex install/             lepton-install: GPT, FAT16, ext2, persistence
  wifi.ex                         Wi-Fi: saved networks, wpa_supplicant manager
  setup.ex tutorial.ex            first-run setup (Wi-Fi prompt), tutorial
  pkg.ex official.ex              lpm, signed official updates
  services.ex power.ex            svc service manager, power button
  selftest.ex                     lepton-test
lib/lepton_build/      image and docs build tooling (not shipped in the image)
lib/mix/tasks/         mix lepton.iso | qemu | shell | publish | official | docs
docs/                  the user guides (Markdown; published to trylepton.app/docs)
rootfs/etc/            /etc files (lshrc, motd, hostname, lepton/services, ssh/ssh_known_hosts, ...)
test/                  ExUnit suite (host + in-OS)
site/                  the website and generated docs (submodule: danieljaouen.github.io, read-only HTTPS)
```
