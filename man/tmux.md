## DESCRIPTION

A terminal multiplexer: several shells in windows and panes on one
terminal, in sessions that keep running when you detach. It reads your
`~/.tmux.conf` (the prefix key, `bind` and `unbind`, options, `\;`
chains, `if-shell` and `source-file`) on top of tmux's defaults, where
the prefix is `C-b`.

With no arguments, start a new session.

## COMMANDS

- `new [-s NAME] [-n WINDOW] [-d] [COMMAND]`: start a session (detached
  with `-d`) running COMMAND or your shell.
- `attach [-t NAME]`, `a`: attach to session NAME (the newest by
  default).
- `ls`: list the sessions.
- `kill-session -t NAME`: end a session and everything running in it.
- `kill-server`: end every session.
- `list-keys`: list the key bindings.
- `source-file FILE`: read FILE's commands into the running sessions.

## KEYS

After the prefix: `d` detach, `c` new window, `n`/`p` next and previous
window, `0`-`9` select window, `%` and `"` split, arrow keys move
between panes, `x` kill pane, `z` zoom, `[` copy mode, `]` paste, `:`
command prompt, `?` list keys. Your `~/.tmux.conf` may change any of
these; `keys tmux` shows the result.

In copy mode (vi keys with `mode-keys vi`), `v` or `Space` starts a
selection and `y` or `Enter` copies it to the clipboard shared with the
editor and `pbcopy`.

Closing a pane (`kill-pane`) ends its shell and everything started in
it.

With `set -g mouse on`, a click selects the pane under it, and programs
that ask for the mouse (`le`) get clicks, drags and the wheel in their
pane. A click on a window's name in the status line selects that
window; the wheel over the status line goes to the next or previous one.

## FILES

- `~/.tmux.conf`: configuration.

## SEE ALSO

keys(1), le(1), lsh(1), https://trylepton.app/docs/tmux.html
