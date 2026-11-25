---
title: The shell (lsh)
order: 2
section: shell
summary: Line editing, your zsh aliases, the starship prompt, jobs and scripting.
---

# The shell: lsh

`lsh` is Lepton's shell. It also answers to `sh`, `zsh` and `bash`, and it
is what logs you in on every console.

## Line editing

The line editor follows oh-my-zsh's emacs bindings (`bindkey -e`):

- zsh-autosuggestions: a dim suggestion from history, accepted with `→`,
  `C-f` or `C-e`;
- zsh-syntax-highlighting: each command (the first, and each after `|`,
  `&&`, `||` or `;`) turns green when it exists and red when it doesn't;
- `C-r` searches history, `Tab` completes commands and paths, and
  `C-x C-e` edits the line in `$EDITOR`; names with spaces or quotes
  complete as the shell reads them: `cat My\ Do`, Tab, gives
  `cat My\ Documents/`, and inside quotes (`cat "My Do`) they stay
  quoted and the quote is closed after a file;
- Alt types accents: Alt+e then `e` is é, Alt+u then `u` is ü (see
  [Typing accents](accents.html));
- pasting (bracketed paste, as zsh does it): pasted lines go into the
  command line, newlines and all, and nothing runs until you press
  Return, which runs them together. This works in Lepton's terminal
  windows, in `tmux`, and over SSH from terminals that support it (macOS's
  Terminal and iTerm2 do);
- **Shift+Enter** (or Alt+Enter) starts a new line in the command
  instead of running it, as in zsh; Return runs it all. Over SSH from a
  Mac, use Option+Enter with "Use Option as Meta key" on, since macOS's
  Terminal sends Shift+Enter as a plain Return.

`bindkey` lists every binding; the [key bindings page](keybindings.html)
shows them too. History is appended after every command
(`inc_append_history`) to `~/.lsh_history`.

## Your ~/.zshrc

`~/.zshrc` is *imported*, not executed:

- `alias` lines (`l`, `gc`, `m`, `mc`, …) are applied;
- simple `export`s, including a BSD `LSCOLORS` that `ls` honours;
- `setopt` options;
- macOS-only `if` branches are skipped and the Linux branch is used;
- `EDITOR=vim` makes `vim` an alias of `le`.

The oh-my-zsh `git` plugin's aliases come from `/etc/lshrc`, and yours
override them. `alias` lists everything that was loaded.

## The prompt

A starship engine reads `~/.config/starship.toml`: the format language,
styles, `username show_always`, `hostname ssh_only = false`,
`directory truncation_length = 1`, and your `git_branch` / `git_status`
formats. If your character symbols are empty strings (stripped Nerd Font
glyphs), starship's `❯` is used, or `>` on the Linux console.

## Pipelines, redirection and jobs

Programs are BEAM processes connected by pipes with back-pressure;
writing to a closed pipe ends the writer, like SIGPIPE.

- `|`, `>`, `>>`, `<`, `2>&1`, `2>/dev/null`; `&&`, `||` and `;`
- `{ …; }` groups and `( … )` subshells
- `&` runs a job in the background; `C-c` interrupts the foreground job
  and `C-z` suspends it; `jobs`, `fg`, `bg` and `wait` manage them
- `ps`, `kill`, `pgrep`, `pkill` and `top` work on the process table;
  see [System](system.html#processes-and-jobs)

## Scripting

- `if`/`elif`/`else`, `for … in`, `while`, `until`, and
  `break [N]` / `continue [N]` (also out of nested loops)
- `$VAR`, `${VAR}`, `$?`, `$$`, `$!`, `$#`, `$@`, `$1`… and `~`
- `$(command)` and backquotes
- `$((expression))`: integer arithmetic with C precedence, including
  comparisons, `&&`, `||` and `!`; names inside are variables
- `test` / `[ … ]` for files, strings and numbers
- scripts: `lsh script.sh ARGS`, or an executable file starting with a
  `#!` line naming a shell; executable `*.exs` files run as Elixir

```sh
i=0
while true; do
  i=$((i + 1))
  [ $i -gt 3 ] && break
  echo "round $i"
done
```

## Builtins

These run inside the shell itself: `cd pwd export unset alias unalias
history exit logout source . jobs fg bg wait type which read eval shift
set setopt unsetopt bindkey hash rehash umask local dirs pushd popd exec
builtin command return break continue`.

`builtin NAME` runs the command shipped with Lepton even when an
[official update](packages.html#official-updates-for-built-in-apps)
stands in for it.

<!-- commands: lsh test env time watch -->
