---
title: The editor (le)
order: 3
section: shell
summary: A Spacemacs-style editor configured from your ~/.spacemacs.
---

# The editor: le

`le` is a Spacemacs work-alike. It also answers to `vi`, `vim`, `nvim`,
`emacs`, `emacsclient`, `spacemacs` and `edit`.

## Read from your configuration

`le` reads `~/.spacemacs` and `~/.spacemacs.d/{editing,keybindings}.el`
with an Emacs Lisp reader, extracting `define-key`, `global-set-key`,
`evil-define-key`, `setq(-default)`, `defalias` and `defun` forms,
including inside `with-eval-after-load`.

| From your config | Effect in `le` |
|---|---|
| `;` → `evil-ex` (normal, visual) | `;` opens the ex prompt |
| `C-h/j/k/l` → `evil-window-*` | window navigation; with the **tmux layer**, at an edge it moves to the neighbouring tmux pane |
| `,w` → `delete-trailing-whitespace` | normal state |
| `,q` → `sort-lines`, `,ah` → `align-repeat` | visual state (your `align-repeat` defun is implemented) |
| insert `C-h` backspace, `C-w` delete word, `C-n`/`C-p` lines | insert state |
| `C-y` unbound, `C-y ,` → `my-tab-command` | indent + yasnippet expansion (snippets from `~/.emacs.d/snippets`) |
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

The full list of what was loaded is on the
[key bindings page](keybindings.html), or `keys editor` inside Lepton.

## Spacemacs defaults

- the `SPC` leader with which-key popups: `SPC f f/s` files, `SPC b b/d`
  buffers, `SPC w /,-,d,m` windows, `SPC g s` git, `SPC p f` project files,
  `SPC s s` search the buffer, `SPC s p` / `SPC /` search the project
  (`RET` on a result opens its file at that line; motions such as `w`
  and `b` move in the results), `SPC t n/r` line numbers, `SPC x a r`
  align, `SPC q q` quit, `SPC SPC` M-x, `SPC ?` bindings;
- helm-style candidate lists;
- evil operators, motions and text objects with counts and `.`, visual
  modes, undo/redo, yank and paste, and splits;
- keyboard macros: `q` and a register (`a`–`z`, `0`–`9`) records what you
  type, `q` stops (the mode line shows `[@q]` meanwhile), `@q` plays it
  back, `@@` plays the last one again, and a count repeats it (`5@q`).
  `qQ` (the capital) adds to macro `q`. Macros last until `le` quits;
- ex commands: `:w :q :wq :e :sp :vsp :s/// :sort :!cmd :r !cmd`;
- the mouse: a click puts the cursor there (and selects that window; on a
  mode line, just the window), a drag selects text as `v` does, and the
  wheel scrolls the window under the pointer three lines. It works in
  Lepton's terminal windows, in `tmux` with `mouse on` (your tmux.conf
  has it), and over SSH from terminals that report the mouse (Terminal
  and iTerm2 on the Mac do).

## Org mode: folding

In `.org` files, headings (`* `, `** `, ...) fold as in Spacemacs:

| Keys | What they do |
|---|---|
| `TAB` on a heading | cycle it: folded, then its child headings, then the whole subtree |
| `S-TAB` | cycle the buffer: top-level headings, then every heading, then everything |
| `zm` (`zM`) | fold every heading: only the top-level ones show |
| `zr` (`zR`) | reveal everything |
| `za`, `zc`, `zo` | toggle, fold or open the heading the cursor is under |

A folded heading ends in `...`. `j` and `k` step over folded text, and a
search (`/`, `n`, `N`) that lands inside a fold opens it. Folds stay put
as you edit above or below them; they last until the file is closed.
`o` on a folded heading opens a line below its subtree; `O` opens one
above, at the end of the entry before it, which stays folded. Lines you
add while something is folded show until you fold again (`zm`, `TAB`).

Bindings that name commands `le` doesn't implement are listed as "not
supported" by `keys` and `SPC h d b`, never silently dropped.

## Git from the editor

`SPC g s` opens a magit-style status buffer: stage with `s`, unstage with
`u`, commit with `c c`, push with `P p`, pull with `F p`, and stash with
`Z`. `s` and `u` take the file under the cursor, or on a section's
heading (Unstaged changes, Untracked files, Staged changes) every file in
it. As magit does, the status buffer first saves your modified buffers
in the repository, so what you typed is what you stage.

To commit, press `c c` (or `c a` to amend the last commit): a buffer
opens for the message, in insert state. Write it, then finish as in
Spacemacs:

| Keys | |
|---|---|
| `, c`, `, ,` or `C-c C-c` (also `:wq`, `ZZ`) | commit |
| `, k`, `, a` or `C-c C-k` | cancel |

`C-c C-c` and `C-c C-k` work in insert state too. Either way you are back
in the status buffer, with the commit (`[main 1a2b3c4] Subject`) in the
echo area; then `P p` pushes. See [git and GitHub](git.html).

<!-- commands: le -->
