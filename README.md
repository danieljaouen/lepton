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
 │   lsh shell · coreutils · le (Spacemacs) · tmux · git · gh · www     │
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
| Linux kernel + modules | Alpine `linux-virt` (v3.24) | the BEAM needs a kernel |
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
[danieljaouen/lepton.iso](https://github.com/danieljaouen/lepton.iso)
([direct download](https://github.com/danieljaouen/lepton.iso/raw/main/lepton.iso)),
and the project site is <https://trylepton.app/>.

## Quick start

Requirements on the build machine: Elixir 1.18+ on **OTP 29** (the image ships
OTP 29.1.2, and compiled `.beam` files must match), `tar`, and network access
for the first build. QEMU (`brew install qemu`) is optional, for testing.

```sh
mix lepton.iso                 # -> out/lepton.iso (dotfiles from ./dotfiles)
mix lepton.iso --dotfiles ~/.dotfiles
mix lepton.qemu                # boot in a QEMU window (UTM-equivalent machine)
mix lepton.qemu --test         # headless boot, run lepton-test, report
mix lepton.qemu --run "uname -a" --run "ip addr"
mix lepton.shell               # run the userland in this terminal, no VM
mix test                       # host-side test run
```

### Running in UTM

1. **Create a New Virtual Machine → Virtualize → Linux**.
2. **Boot ISO Image**: choose `out/lepton.iso`. Leave "Use Apple
   Virtualization" unchecked (the QEMU backend is the tested path).
3. Memory: 2048 MB or more; CPU: 2+ cores. Storage: any size (Lepton runs
   from RAM and does not touch the disk).
4. Optional: **Devices → New → Serial**, to get a second login session in
   UTM's terminal window. That window speaks xterm, so 256 colours and Unicode
   glyphs look better there than on the framebuffer console.
5. Start the VM. GRUB boots the default entry after 3 seconds. Other entries
   give a verbose boot and a boot that runs the self-tests automatically.

You are logged in as `root`, on the display console (`tty1`) and on the
serial port (`ttyAMA0`) if present. `hvc0` is used under Apple
Virtualization. Networking comes up by DHCP in the background.

### Installing to a disk (UTM)

The live ISO runs entirely from RAM. To keep your files, install to a
virtual disk:

1. With the VM stopped: **Drives → New → VirtIO** (or NVMe), 4 GB or more.
2. Boot the ISO and run `lepton-install` (it asks which disk and asks you
   to confirm; `lepton-install -y /dev/vda` skips both).
3. `poweroff`, then **CD/DVD → Clear** to eject the ISO, and start the VM.

The installer writes everything itself, in Elixir: a GPT partition table,
a FAT16 EFI system partition (GRUB, kernel and initramfs copied from the
ISO), and an ext2 data partition named `LEPTON-DATA`
(`lib/lepton/install/`). The installed system still boots into RAM, but
`/root` and `/var/lib/lepton` (packages, Wi-Fi credentials, setup state)
are bind-mounted from the data partition. On the first boot, `/root` is
seeded from the image, including your dotfiles.

**Shutting down.** Use UTM's power button → **Request power down** (or
type `poweroff`). Lepton listens for the virtual power button (ACPI
through the `gpio-pl061` and `button` drivers, read in `Lepton.Power`),
warns the consoles, flushes the data partition, remounts it read-only and
powers off, so the next start is a clean boot through GRUB. "Force shut
down" and closing the VM window pull the plug and can't be intercepted.

With QEMU: `qemu-img create -f qcow2 disk.qcow2 8G`, then
`mix lepton.qemu --disk disk.qcow2` to install and
`mix lepton.qemu --no-cd --disk disk.qcow2` to boot the installed system.

### First-run setup: Wi-Fi and the tutorial

- **Wi-Fi.** The automatic Wi-Fi prompt at startup and after installation
  is **turned off for now**, because Lepton can't join Wi-Fi networks yet
  (see the limitation below). Re-enable it with `@wifi_prompt true` in
  `lib/lepton/setup.ex`. Credentials can still be entered manually with
  `wifi setup`. They are saved in wpa_supplicant format
  (`/var/lib/lepton/wpa_supplicant.conf`), with the passphrase stored only
  as its WPA PSK (PBKDF2, the same value `wpa_passphrase` computes).
  `wifi` shows status, `wifi setup` asks again, and `wifi forget` clears
  them. **Limitation:** Lepton cannot join a Wi-Fi network yet. The
  shipped kernel (`linux-virt`) has no 802.11 stack or Wi-Fi drivers, and
  UTM/QEMU VMs have no wireless hardware, since their network is virtio
  ethernet, which DHCP configures automatically. The saved credentials are
  meant for a future kernel with Wi-Fi support.
- **Tutorial.** On the first boot after installation, Lepton offers a
  10-lesson tour (once). It covers files, pipes, jobs, the editor, tmux,
  git/GitHub, packages, networking and help, using the key bindings from
  your dotfiles. Each lesson suggests a command that you can run for
  real. `lepton-tutorial` runs it any time.

### Packages: `lpm` (hex.pm)

`lpm` installs Elixir and Erlang packages directly from
[hex.pm](https://hex.pm). It resolves version requirements and
dependencies through the Hex API, downloads the tarballs, verifies them
against the registry's SHA-256 checksum, and compiles them *inside
Lepton* with the Elixir and Erlang compilers in the image. Packages are
loaded at every boot.

```sh
lpm search json
lpm info jason
lpm install jason           # or jason@~>1.4, several at once
elixir -e 'IO.puts Jason.encode!(%{hello: "lepton"})'
lpm install ./my_tool       # a local Mix project
lpm list | lpm remove NAME | lpm update
```

A package can add shell commands. Any module that does
`use Lepton.Command` and defines `defcmd`s becomes a command when the
package loads, so a Lepton tool can be published to hex.pm like any other
library. Packages built on Mix-specific features (compile-time config,
application callbacks in `mix.exs`, NIFs) are not supported yet.

## Your dotfiles, applied

The build installs your dotfiles repo into `/root` following its own
`locations/` convention (`*.symlink` → `~/.name`, `*.directory.symlink` →
directories). Each program then reads its native config file at runtime.
`keys` (or `keys editor|tmux|git|shell`) prints exactly what was loaded.

**Editor (`le`; also `vi`, `vim`, `nvim`, `emacs`, `emacsclient`, `e`)**:
reads `~/.spacemacs` and `~/.spacemacs.d/{editing,keybindings}.el` with an
Emacs Lisp reader (`Lepton.Elisp`), extracting `define-key`,
`global-set-key`, `evil-define-key`, `setq(-default)`, `defalias` and
`defun` forms, including inside `with-eval-after-load`.

| From your config | Effect in `le` |
|---|---|
| `;` → `evil-ex` (normal, visual) | `;` opens the ex prompt |
| `C-h/j/k/l` → `evil-window-*` | window navigation; with the **tmux layer**, at an edge it moves to the neighbouring tmux pane |
| `,w` → `delete-trailing-whitespace` | normal state |
| `,q` → `sort-lines`, `,ah` → `align-repeat` | visual state (your `align-repeat` defun is implemented) |
| insert `C-h` backspace, `C-w` delete word, `C-n`/`C-p` lines | insert state |
| `C-y` unbound, `C-y ,` → `my-tab-command` | indent + yasnippet expansion (snippets read from `~/.emacs.d/snippets`) |
| evilified `/ ? n N`, `Buffer-menu` `k` | magit, dired, help and list buffers |
| company `C-n/C-p/C-w/C-h`, `C-d o`/`C-d t` (EEx tags) | completion popup |
| magit `C-j/C-k`, `/ n N`, `Z` stash, `zt`/`zz` | `SPC g s` status buffer |
| `evil-escape-key-sequence "jk"`, delay 0.4 | `jk` leaves insert state |
| `display-line-numbers-type 'relative` | relative line numbers |
| `display-fill-column-indicator-column 101`, `fill-column 79` | indicator at column 101 |
| `case-fold-search nil` | case-sensitive search |
| `before-save-hook delete-trailing-whitespace` | applied on save |
| `defalias 'sl 'sort-lines` | `:sl` / `M-x sl` |
| `dotspacemacs-themes '(monokai …)` | Monokai palette |

Spacemacs defaults are built in: the `SPC` leader tree with which-key
popups (`SPC f f/s`, `SPC b b/d`, `SPC w /,-,d,m`, `SPC g s`, `SPC p f`,
`SPC s s`, `SPC /`, `SPC t n/r`, `SPC x a r`, `SPC q q`, `SPC SPC` M-x,
`SPC ?`), helm-style candidate lists, evil operators/motions/text objects
with counts and `.`, visual modes, undo/redo, splits, and ex commands
(`:w :q :wq :e :sp :vsp :s/// :sort :!cmd :r !cmd`). Bindings that name
commands `le` does not implement are listed as "not supported" by `keys` /
`SPC h d b`, never silently dropped.

**Multiplexer (`tmux`)**: interprets your `~/.tmux.conf`: `set -g prefix
C-t`, every `bind`/`unbind` (`-r` repeat, `-n` root table, `-T
copy-mode-vi`), `\;` command chains, `mode-keys vi`, `history-limit 100000`,
`monitor-activity`, `set-titles`, and `if-shell "uname | grep -q Linux"
"source-file ~/.tmux.linux.conf"` (the test runs in lsh, so the Linux branch
is taken and `Y` pipes to `xclip`). Your zoom hack (`+`/`-`, built on
`new-window -d -n tmux-zoom` and cross-window `swap-pane`) works as written.
`@themepack powerline/default/cyan` sets the status line colours; TPM and
resurrect/continuum are not run. Sessions persist after `prefix d`;
reattach with `tmux attach`.

**Shell (`lsh`; also `sh`, `zsh`, `bash`)**: oh-my-zsh's emacs line editing
(`bindkey -e`), zsh-autosuggestions (dim history suggestion, `→`/`C-f`/`C-e`
accept), zsh-syntax-highlighting (command green/red), `C-r` search,
completion, and `C-x C-e` to edit in `$EDITOR`. `~/.zshrc` is *imported*,
not executed: `alias` lines (`l`, `gc`, `m`, `mc`, …), simple `export`s
(including your BSD `LSCOLORS`, honoured by `ls`) and `setopt` are applied,
macOS-only `if` branches are skipped and the Linux branch used, and
`EDITOR=vim` makes `vim` an alias of `le`. oh-my-zsh `git`-plugin aliases
come from `/etc/lshrc`, and yours override them (`gp`, `gc`). History is
appended per command (`inc_append_history`).

**Prompt**: a starship engine reads `~/.config/starship.toml` (format
language, styles, `username show_always`, `hostname ssh_only = false`,
`directory truncation_length = 1`, your `git_branch`/`git_status` formats).
Your character symbols are empty strings (stripped Nerd Font glyphs), so
starship's `❯` is used, or `>` on the Linux console.

**git**: format-compatible with upstream git (loose and packed objects,
index v2, refs, packed-refs, `.gitignore`). `~/.gitconfig` is honoured,
including `[include] path = .gitconfig.local`, all your aliases (`gl`, `gll`
with `--pretty=format:` placeholders, `st`, `ci`, `co`, `br`, `df`, `dc`,
`lg`, `ls`, `ign`, `ull`/`ll`, `ush`/`sh`), `user.name`/`email`,
`core.pager = cat`, `core.excludesfile`, and `http.sslVerify`.

**GitHub**: `git clone/fetch/pull/push` speak smart HTTP to GitHub
(side-band-64k packs, OFS/REF deltas). `gh auth login` stores a token in the
same `~/.config/gh/hosts.yml` format GitHub's `gh` uses (or set `GH_TOKEN`),
and `git push` uses it. `gh repo view|list|clone|create`, `gh issue
list|view|create`, `gh pr list|view`, `gh browse`, `gh api`. In the editor,
`SPC g s` then `P p` pushes and `F p` pulls.

**iex**: loads `~/.iex.exs`, so your `MyIExHelpers` work: `sh "ls"` and
`~x(ls -la)` run commands in lsh.

## Commands

`help` lists everything, and `man CMD` describes one. In summary:

- **files**: `ls cat cp mv rm mkdir rmdir touch ln readlink chmod stat find tree du df basename dirname realpath`
- **text**: `grep head tail wc sort uniq cut tr sed awk diff xargs nl rev tac less/more base64 md5sum sha1sum sha256sum sha512sum strings hexdump/xxd`
- **shell utils**: `echo printf true false yes seq test/[ expr env printenv time watch sleep date cal clear reset resize stty tty`
- **system**: `ps kill pgrep pkill top free uptime uname hostname whoami id mount umount dmesg lsmod modprobe rmmod sync reboot poweroff neofetch keys`
- **network**: `ip ifconfig dhclient ping nslookup/host curl/wget www`
- **dev**: `le tmux git gh iex elixir mix erl lsh lepton-test`
- **admin**: `lepton-install lepton-tutorial lpm wifi credits`
- **clipboard**: `pbcopy pbpaste xclip` (shared with tmux copy mode and editor yanks; also sent to the host terminal with OSC 52)

Executable `*.exs` files on `$PATH` run as Elixir scripts, and files
starting with `#!` naming a shell run in lsh. Commands can also be added at
runtime with `Lepton.Commands.register/2` (for example from `iex`).

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
  uses `:ssl` with the bundled CA roots.

## Testing

`lepton-test` (inside the OS) compiles and runs the same `test/*_test.exs`
files that `mix test` runs on a Mac. Tags pick tests by environment:
`:native` needs the real system (PID 1, mounts, loaded drivers, installed
dotfiles); `:network` needs internet access (DHCP, DNS, and cloning
`octocat/Hello-World` from GitHub) and is enabled automatically when the
network is up; `:dotfiles` needs your dotfiles. Options: `--only TAG`,
`--include TAG`, `-v`, or file paths.

Current results: 82 tests, 0 failures inside the VM (none excluded; run on
an installed system), and 75 passing plus 7 excluded (native/network) on
the host.

## Limitations

- The live ISO keeps everything in RAM. An installed system persists
  `/root` and `/var/lib/lepton` only. Changes elsewhere (for example
  `/etc`) reset at boot.
- Wi-Fi credentials can be saved but not used: see "First-run setup".
- Single user (`root`), no permissions model beyond the kernel's.
- git: no three-way merge (pulls fast-forward only), no rebase, and no SSH
  transport (HTTPS only).
- `le` is a Spacemacs work-alike, not Emacs: no Elisp *evaluation*, so
  layers and packages are not loaded. Unsupported bindings are reported.
- ELF binaries can run through `Port` (stdin/stdout only, no pty).
- The Linux framebuffer console approximates 256-colour themes. A serial
  console in an xterm-compatible terminal renders the Monokai palette fully.

## Roadmap: GUI and web browser

The CLI layers were built so a graphical stack can sit on top of them:

1. **Display**: the kernel already provides a DRM/fbdev framebuffer
   (`simpledrm`/`virtio-gpu` are loaded at boot). Phase 1 writes pixels to
   `/dev/fb0` from Elixir (mode queried via sysfs). Phase 2 uses DRM dumb
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
  git.ex git/ gh.ex               git + GitHub
  net.ex browser.ex screen.ex     networking, text browser, VT emulator
  dotfiles.ex elisp.ex toml.ex    config readers
  install.ex install/             lepton-install: GPT, FAT16, ext2, persistence
  setup.ex tutorial.ex pkg.ex     first-run setup (Wi-Fi prompt off), tutorial, lpm
  selftest.ex                     lepton-test
lib/lepton_build/      image build tooling (not shipped in the image)
lib/mix/tasks/         mix lepton.iso | lepton.qemu | lepton.shell
rootfs/etc/            /etc files (lshrc, motd, hostname, ...)
test/                  ExUnit suite (host + in-OS)
dotfiles/              your dotfiles repo (input to the build)
site/                  the showcase website (submodule: danieljaouen.github.io)
```
