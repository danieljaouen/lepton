---
title: The multiplexer (tmux)
order: 4
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

## Copy mode

`prefix [` enters vi copy mode: move with the vi keys, `v` starts a
selection and `y` copies it to the clipboard shared with the editor,
`pbcopy` and `pbpaste` (and with your computer's clipboard over OSC 52).

## Moving between the editor and panes

With the Spacemacs **tmux layer** enabled, `C-h/j/k/l` in `le` moves
between editor windows and, at an edge, on to the neighbouring tmux pane.

Every binding loaded from your configuration is on the
[key bindings page](keybindings.html#tmux).

<!-- commands: tmux -->
