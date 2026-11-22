---
title: Claude Code
order: 6
section: shell
summary: Run Claude Code, Anthropic's coding agent, on Lepton: install it with one command, log in, and let it work on your projects with bash, git, ripgrep, mix and elixir.
---

# Claude Code

[Claude Code](https://code.claude.com/docs) is Anthropic's coding agent
for the terminal: you ask it in plain words to explain, change or test
your code, and it reads files, edits them and runs commands to do it.
It runs on Lepton.

Claude Code isn't open source, so it isn't part of Lepton. Lepton
downloads Anthropic's own build for Linux on arm64 from Anthropic,
the way Anthropic's installer does, and checks it against the release's
checksum. Using it is subject to Anthropic's terms, and needs a Claude
account (Pro, Max, Team or Enterprise) or an Anthropic Console account.

## Install it

```sh
sudo claude-code install
```

This installs two things:

1. the programs Claude Code expects of a Linux system, from Alpine:
   bash, git, ripgrep and util-linux (33 packages, about 14 MB to
   download, 39 MB installed);
2. Claude Code itself, Anthropic's `linux-arm64-musl` build of the latest
   release (about 365 MB), in `/var/lib/lepton/claude-code`.

On an installed system both are kept on the data partition. On the live
ISO they are kept in memory, so give the VM at least 4 GB, and they are
gone after a reboot.

```sh
claude-code                 # installed? which version?
sudo claude-code update     # the latest release
sudo claude-code remove     # remove it (your ~/.claude is kept)
```

Claude Code doesn't update itself on Lepton: `sudo claude-code update`
does. `claude update` just says so.

## Use it

```sh
cd ~/src/myapp
claude
```

The first time, it asks you to pick a text style and to log in: choose
your Claude account or a Console account, and it shows a link. Open the
link in a browser: [Firefox](apps.html) on Lepton's desktop, or on your
Mac. Sign in, and paste the code you get back into Claude Code. Your login
and settings are kept in `~/.claude`, as on any other system. Instead of
logging in, you can set `ANTHROPIC_API_KEY`.

Everything else works as Claude Code's documentation describes: type what
you want, `/help` for its commands, `Esc` to interrupt it, `C-c` twice to
quit. For one question without the interface, use print mode:

```sh
claude -p "what does lib/myapp/accounts.ex do?"
git diff | claude -p "review this change"
```

## The commands it runs

Claude Code runs commands in **bash**, Alpine's, not in Lepton's shell.
There it has:

- bash, git, ripgrep (`rg`) and util-linux;
- `mix` and `elixir`, the image's Elixir and Erlang, each in a VM of its
  own, as Lepton's own [`mix`](phoenix.html) runs: `mix test`,
  `mix compile` and `mix phx.server` work;
- busybox's versions of the usual Unix programs (`ls`, `grep`, `sed`,
  `find`, `wget` and so on);
- QEMU, once it is installed (`sudo app install qemu`): with it, in a
  checkout of Lepton, `mix lepton.qemu --test` runs Lepton's self-tests in
  a [virtual machine](virtual-machines.html).

Lepton's own commands (`svc`, `app`, `vm`, `photon`, Lepton's `git`, ...)
are functions in Lepton's VM, not programs, so bash can't run them
directly. It runs them through `lepton`:

```sh
lepton svc status
lepton vm start test
lepton -c 'vm log test | tail -5'
```

`lepton` sends the command line to Lepton, which runs it as you, and
prints what it prints. Commands that need a terminal (`le`,
`vm console`) don't work this way. Claude Code finds `lepton` on its path
and can use it like any other command.

It runs as you, with your files and your permissions. It can change the
files you can change, so review what it proposes, as anywhere.

## How it runs

Claude Code's interface needs a real terminal, which a native program on
Lepton doesn't get, because Lepton's terminals are Lepton's own. So
`claude` runs it under util-linux's `script`, which gives it a
pseudo-terminal and passes it your keys and its output. When the window
changes size, Lepton tells Claude Code. When its output isn't a terminal
(`claude -p ... | less`, or in a script), it runs on plain pipes instead.

<!-- commands: claude claude-code -->
