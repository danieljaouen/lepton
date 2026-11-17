---
title: System
order: 11
summary: Processes and jobs, storage and persistence, power, the clipboard, Elixir and the self-tests.
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
`/etc`, resets at boot.

`df`, `du`, `free` and `mount` show filesystems and memory.

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
share one clipboard with tmux copy mode and editor yanks. Copies are also
sent to your computer's terminal with OSC 52, so they can land in the Mac
clipboard over a serial console.

## Elixir and Erlang

- `iex` is interactive Elixir. It loads `~/.iex.exs`, so your helpers
  work: `sh "ls"` and `~x(ls -la)` run commands in `lsh`.
- `elixir -e CODE`, or `elixir FILE.exs`; executable `*.exs` files on
  the path run as Elixir scripts.
- `mix` runs in the project in the current directory.
- Commands can be added at runtime with `Lepton.Commands.register/2`, or
  by [packages](packages.html#packages-that-add-commands).

## Help and information

`help` lists every command, and `man CMD` or `help CMD` describes one
(the [command reference](commands.html) has them all). `keys` shows the
bindings loaded from your dotfiles, `neofetch` summarises the system, and
`credits` says who made Lepton. The login message and `help` point here,
to <https://trylepton.app/docs/>.

## Self-tests

`lepton-test` runs Lepton's ExUnit test suite inside the running system:
mounts, drivers, DHCP, the shell, editor, multiplexer, git, packages and
services. `--only TAG` and file arguments pick tests.

<!-- commands: ps top kill pgrep pkill df du free mount poweroff reboot resize pbcopy pbpaste iex elixir mix help man keys neofetch lepton-test -->
