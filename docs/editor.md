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
  `SPC s s` / `SPC /` search, `SPC t n/r` line numbers, `SPC x a r`
  align, `SPC q q` quit, `SPC SPC` M-x, `SPC ?` bindings;
- helm-style candidate lists;
- evil operators, motions and text objects with counts and `.`, visual
  modes, undo/redo, yank and paste, and splits;
- ex commands: `:w :q :wq :e :sp :vsp :s/// :sort :!cmd :r !cmd`.

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

Bindings that name commands `le` doesn't implement are listed as "not
supported" by `keys` and `SPC h d b`, never silently dropped.

## Git from the editor

`SPC g s` opens a magit-style status buffer: stage with `s`, unstage with
`u`, commit with `c c`, push with `P p`, pull with `F p`, and stash with
`Z`. See [git and GitHub](git.html).

<!-- commands: le -->
