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
counts, `.`, visual modes (`v`, `V` and `C-v`, visual block), marks (`ma`
sets mark a, `'a` goes to its line and `` `a `` to the very place; `A`-`Z`
work across files, `''` goes back, `:marks` lists them), registers (`"ayy` yanks into register a and `"ap`
pastes it; `"A` appends, `"_` discards, `"0` is the last yank, `"+` the
clipboard, `:reg` lists them), `u` and `C-r`, registers, splits, and
keyboard macros (`qq` ... `q` records into register q, `@q` plays it,
`@@` again, `5@q` five times, `qQ` appends; as in Vim, a motion that
can't move, such as `j` on the last line, stops the macro, so `100@q`
ends at the end of the file; macros are saved, so later sessions have
them too). Ex commands
include `:w`, `:q`, `:wq`, `:e FILE`, `:sp`, `:vsp`, `:s/A/B/g`,
`:sort`, `:!CMD` and `:r !CMD`. Some Spacemacs leader keys:

- `SPC f f` open a file, `SPC f s` save, `SPC f S` (or `C-x s`, `:wa`)
  save every changed file.
- `SPC b b` switch buffer, `SPC b d` close buffer.
- `SPC w /` and `SPC w -` split, `SPC w d` close window, `SPC w m`
  maximise.
- `SPC p f` find a file in the project, `SPC s s` search the buffer,
  `SPC s p` or `SPC /` search the project (`RET` on a result opens it).
- `SPC p R` replace in the whole project (`SPC p %`: a regexp): each
  match asks `y` (replace), `n` (skip), `!` (all the rest), `.` (this one
  and stop) or `q`; the files changed are saved with `:wa` (`SPC f S`).
  In a git repository, what `.gitignore` leaves out is left alone.
  `SPC s R` (`SPC s %`) does the same in a directory you name, every file
  under it, ignored ones too (never `.git`).
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

A paste from the terminal (bracketed paste) goes in exactly as copied,
without auto-indent, in any mode.

Options (`-...`) and `+LINE` arguments are accepted and ignored.

## FILES

- `~/.spacemacs`, `~/.spacemacs.d/*.el`: configuration.
- `~/.emacs.d/snippets`: yasnippet snippets.
- `~/.local/state/le/macros` (`$XDG_STATE_HOME/le/macros`): keyboard
  macros, saved when recorded and loaded at start; one a line, a register
  and its keys (`a ["I", "-", " ", "ESC", "j"]`; a newline in a key is written `\n`,
  so each macro stays on its line). Edit it to change or
  remove one.

## SEE ALSO

keys(1), git(1), tmux(1), https://trylepton.app/docs/editor.html
