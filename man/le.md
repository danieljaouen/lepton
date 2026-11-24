## DESCRIPTION

`le` is Lepton's text editor, a work-alike of Spacemacs: evil (vi)
editing with the `SPC` leader key. It opens each FILE in a buffer (a
new file is created when you save). It also answers to `vi`, `vim`,
`nvim`, `emacs`, `emacsclient`, `spacemacs` and `edit`, so `$EDITOR` and
git's commit messages open it.

`le` reads your configuration rather than running it: `~/.spacemacs`
and `~/.spacemacs.d/` are parsed for key bindings (`define-key`,
`evil-define-key`, `global-set-key`), variables (`setq`), aliases and
some functions. `keys editor` lists what was loaded and marks bindings
it does not support.

## KEYS

The vi keys work as in Vim: motions, operators and text objects with
counts, `.`, visual modes, `u` and `C-r`, registers, splits, and
keyboard macros (`qq` ... `q` records into register q, `@q` plays it,
`@@` again, `5@q` five times, `qQ` appends). Ex commands
include `:w`, `:q`, `:wq`, `:e FILE`, `:sp`, `:vsp`, `:s/A/B/g`,
`:sort`, `:!CMD` and `:r !CMD`. Some Spacemacs leader keys:

- `SPC f f` open a file, `SPC f s` save.
- `SPC b b` switch buffer, `SPC b d` close buffer.
- `SPC w /` and `SPC w -` split, `SPC w d` close window, `SPC w m`
  maximise.
- `SPC p f` find a file in the project, `SPC s s` search the buffer,
  `SPC s p` or `SPC /` search the project (`RET` on a result opens it).
- `SPC g s` git status (magit-style: `s` stage, `u` unstage, `c c`
  commit, `P p` push, `F p` pull). In the commit message, `, c` or
  `C-c C-c` (or `:wq`) commits and `, k` or `C-c C-k` cancels; both
  return to the status.
- `SPC SPC` run a command by name (M-x), `SPC ?` list bindings.
- `SPC q q` quit.

In Org files (`.org`), `TAB` on a heading cycles it (folded, children,
subtree) and `S-TAB` cycles the whole buffer; `zm` folds every heading,
`zr` reveals everything, and `za`, `zc` and `zo` toggle, fold and open
the heading under the cursor.

The mouse: a click puts the cursor where you click (and selects that
window; a click on a mode line just selects the window), dragging
selects text as `v` does, and the wheel scrolls the window under the
pointer three lines. It works in Lepton's terminal windows, in `tmux`
with `mouse on`, and over SSH from a terminal that reports the mouse
(most do).

With the Spacemacs tmux layer, `C-h`, `C-j`, `C-k` and `C-l` move
between windows and on into neighbouring tmux panes.

Options (`-...`) and `+LINE` arguments are accepted and ignored.

## FILES

- `~/.spacemacs`, `~/.spacemacs.d/*.el`: configuration.
- `~/.emacs.d/snippets`: yasnippet snippets.

## SEE ALSO

keys(1), git(1), tmux(1), https://trylepton.app/docs/editor.html
