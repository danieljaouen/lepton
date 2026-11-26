---
title: The multiplexer (tmux)
order: 4
section: shell
summary: tmux sessions, windows and panes, driven by your ~/.tmux.conf.
---

# The multiplexer: tmux

`tmux` interprets your `~/.tmux.conf`:

- `set -g prefix C-t` (your prefix) and every `bind` / `unbind`,
  including `-r` (repeat), `-n` (root table) and `-T copy-mode-vi`;
- `\;` command chains;
- `mode-keys vi`, `history-limit 100000`, `monitor-activity` and
  `set-titles`;
- `if-shell "uname | grep -q Linux" "source-file ~/.tmux.linux.conf"`.
  The test runs in `lsh`, so the Linux branch is taken and `Y` in copy
  mode pipes to `xclip`.

Your zoom hack (`+`/`-`, built on `new-window -d -n tmux-zoom` and
cross-window `swap-pane`) works as written. `@themepack
powerline/default/cyan` sets the status line colours. TPM and
resurrect/continuum plugins are not run.

## Sessions

Sessions keep running after you detach with `prefix d`. Reattach with
`tmux attach` (or `tmux attach -t NAME`); `tmux ls` lists them.

`kill-pane` ends the pane's shell and everything running in it,
background jobs too; `kill-session` does that for every pane.

Inside a session, `tmux` won't start another one in the same terminal
("sessions should be nested with care"), as tmux won't. To nest one on
purpose, run `TMUX= tmux` (or `unset TMUX` first); `tmux new -d` (in the
background) is always allowed. With the same prefix at both levels,
press it twice for the inner session (`C-t C-t c`), when your
`~/.tmux.conf` binds the prefix to `send-prefix`.

## Copy mode

`prefix [` enters vi copy mode: move with the vi keys (`{` and `}` by
paragraph, to the blank line before or after), `v` starts a
selection and `y` copies it to the clipboard shared with the editor,
`pbcopy` and `pbpaste` (and with your computer's clipboard over OSC 52).

## The mouse

With `set -g mouse on` (as in your tmux.conf), a click selects the pane
under it, and programs that ask for the mouse, such as `le`, get clicks,
drags and the wheel in their pane. In the status line, a click on a
window's name (`0:zsh`, `1:notes*` ...) switches to that window, and the
wheel there goes to the next or previous one: open a window with
`prefix c`, name it with `prefix ,`, and click the other to go back.

## Moving between the editor and panes

With the Spacemacs **tmux layer** enabled, `C-h/j/k/l` in `le` moves
between editor windows and, at an edge, on to the neighbouring tmux pane.

Every binding loaded from your configuration is on the
[key bindings page](keybindings.html#tmux).

<!-- commands: tmux -->
