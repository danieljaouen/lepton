---
title: System
order: 11
section: system
summary: Processes and jobs, storage and persistence, running out of memory, logs, power, the clipboard, Elixir and the self-tests.
---

# System

## Processes and jobs

Every Lepton program is a BEAM process with a Unix-style PID, a parent, a
terminal and a state. PID 1 is Lepton itself.

- `ps` lists them, `top` shows them live (`q` quits), and `pgrep` /
  `pkill` find or signal them by name;
- `kill PID` terminates a process, `kill -9` kills it, and `kill -STOP` /
  `kill -CONT` suspend and resume it;
- in the shell, `C-c` interrupts the foreground job, `C-z` suspends it,
  and `jobs`, `fg`, `bg` and `wait` manage background jobs.

For long-running apps that should survive logouts and restart when they
fail, use [services](services.html).

## Storage and persistence

The live ISO runs entirely from RAM: nothing you do is kept. An
[installed](getting-started.html#install-to-a-disk) system keeps `/home`
(your files), `/root` and `/var/lib/lepton` (accounts, packages, services,
logs and settings) on its data partition; everything else, including
`/etc`, resets at boot. It keeps `/var/log` too (see [logs](#logs)).

`df`, `du`, `free` and `mount` show filesystems and memory.

## When memory runs out

Lepton has no swap, so the memory the VM has is all there is. Firefox
uses most of it: each tab is a program of its own. When memory runs
short:

1. At 10% left, Firefox unloads tabs you haven't looked at for a while.
   They stay in the tab bar and load again when you go back to them.
2. At 5% left (and at least 160 MiB), Lepton stops the largest of
   Firefox's tabs. That tab shows **Gah. Your tab just crashed.**, and
   **Reload Tab** brings it back. If there is no tab to stop, Lepton
   stops the largest app program instead.

Without step 2 the whole system would freeze: Linux keeps going until
almost nothing is left, and before that it spends all its time reading
programs back from the disk. Lepton's own processes are never stopped.

Each time Lepton stops a program, `dmesg` shows it (`lepton: memory:
... stopping process ...`). `free -h` shows how much memory is available. If
this happens often, give the VM more memory (in UTM: the VM's settings →
**System** → **Memory**), or keep fewer tabs open.

## Logs

Lepton logs what its services do to `/var/log/messages`, with the
kernel's messages among them (`kernel: ...`). `dmesg` shows the kernel's
log alone, and `less /var/log/messages` the whole log. Its times are UTC,
whatever the [time zone](time.html); the services' own logs (`svc logs`)
are in local time.

The live ISO keeps the log in memory, so a restart erases it. An
installed system keeps `/var/log` on its data partition:

- at each boot, the last boot's log moves to
  `/var/log/messages.previous`, so after a crash it shows what led up to
  it;
- if Lepton itself stops, its crash dump goes to
  `/var/log/erl_crash.dump`.

When the log reaches 4 MiB, it moves to `messages.0` (replacing the one
there) and a new one starts.

## Power

`poweroff` (also `halt`, `shutdown`) and `reboot` stop services, flush the
data partition and remount it read-only first. They need root: `sudo
poweroff`. UTM's **Request power down** does the same through the virtual
power button.

## Terminals

Each console runs a login session as `root`. On a serial console,
full-screen programs (`le`, `tmux`, `less`, `top`) follow the terminal
window's size as you resize it; `resize` sets the size by hand. Colours
follow your terminal; `NO_COLOR=1` turns them off.

## Clipboard

`pbcopy` and `pbpaste` (also `xclip`, `xsel`, `wl-copy`, `wl-paste`)
share one clipboard with tmux copy mode, editor yanks and the programs on
the [desktop](desktop.html#the-clipboard), such as Firefox.

### Sharing it with your Mac (UTM)

In UTM, Lepton's clipboard and your Mac's are one: copy on the Mac and
`pbpaste` has it, so a public key copied on the Mac goes straight in:

```sh
pbpaste >> ~/.ssh/authorized_keys
```

and what you copy in Lepton (`pbcopy`, tmux, the editor, Firefox) can be
pasted on the Mac with Cmd-V. This is UTM's **Clipboard Sharing** (VM
settings → **Sharing**), which is on by default; Lepton speaks the SPICE
guest agent's protocol to it, as `spice-vdagent` does on other Linux
systems. Only text is shared. If `pbpaste` still has nothing after you
copy on the Mac, check that setting is on and restart the VM (the
setting adds a device). Other SPICE clients (virt-manager, `remote-viewer`)
work the same way.

Copies are also sent to your computer's terminal with OSC 52, so they can
land in the Mac clipboard over a serial console or SSH too.

## Elixir and Erlang

- `iex` is interactive Elixir. It loads `~/.iex.exs`, so your helpers
  work: `sh "ls"` and `~x(ls -la)` run commands in `lsh`.
- `elixir -e CODE`, or `elixir FILE.exs`; executable `*.exs` files on
  the path run as Elixir scripts.
- `mix` runs in the project in the current directory, in an Erlang VM
  of its own (not Lepton's), as you: Hex, archives and
  [Phoenix](web.html#a-new-phoenix-app-step-by-step) work as elsewhere. `iex -S mix` doesn't, as
  `iex` is Lepton's.
- Commands can be added at runtime with `Lepton.Commands.register/2`, or
  by [packages](packages.html#packages-that-add-commands).

## Help and information

`help` lists every command, and `help CMD` gives one's usage in a line or
two. `man CMD` shows its manual page: what it does, every option, and
examples. Every command has one, and so does each shell builtin (`man
cd`, or `man builtins` for them all).

```sh
man ls              # the manual page, in the pager: Space, /search, q to quit
man -k usb          # pages whose name or summary mentions usb
man -f grep         # grep's one-line summary
man ls | grep -- -h # plain text when it isn't a terminal
```

`MANWIDTH` sets the width pages are laid out at (by default the
terminal's, up to 80 columns). The same pages are on this site:
[manual pages](man.html).

`keys` shows the bindings loaded from your dotfiles, `neofetch`
summarises the system, and `credits` says who made Lepton. The login
message and `help` point here, to <https://trylepton.app/docs/>.

## Self-tests

`lepton-test` runs Lepton's ExUnit test suite inside the running system:
mounts, drivers, DHCP, the shell, editor, multiplexer, git, packages and
services. `--only TAG` and file arguments pick tests.

<!-- commands: ps top kill pgrep pkill df du free mount poweroff reboot resize pbcopy pbpaste iex elixir mix help man keys neofetch lepton-test -->
