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

- the `SPC` leader with which-key popups: `SPC f f/s` files (`SPC f S` or `C-x s` saves every changed one), `SPC b b/d`
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
  `qQ` (the capital) adds to macro `q`. As in Vim, a motion that can't
  move (`j` on the last line, `f` without its character) stops the
  macro and its count, so `100@q` with a `j` in it ends at the last
  line. Macros are kept across sessions: each one is saved when you stop
  recording, to `~/.local/state/le/macros` (`$XDG_STATE_HOME/le/macros`
  if set), and `le` loads them when it starts. Recording a register
  again replaces its macro there too; `qQ` adds to the one last saved.
  Other registers are kept, so a macro recorded in
  another `le` meanwhile is found when you play it. The file holds one
  macro a line, its register and its keys (`a ["I", "-", " ", "ESC",
  "j"]`): edit it to change or delete one, or record an empty one
  (`qaq`);
- visual block (`C-v`), as in Vim: a rectangle of text, its columns as
  they show (tabs and wide characters too). `d`/`x` delete it, `y` copies
  it (and `p`/`P` put it back as a block beside the lines below, or as
  lines of their own on an empty line, which stays after them), `c` changes it, `I` inserts
  before it and `A` appends after it on every line (`$` first: at each
  line's end), `r` replaces each character, `~`/`u`/`U` change the case,
  `o`/`O` move to another corner, and `>`, `<` and `:` work on its lines;
- marks, as in Vim: `m` and a letter marks the place, `'` and the letter
  goes back to its line (`` ` `` and the letter: to the very place), and
  both work after an operator (`d'a` deletes down to mark a). Marks move
  with their text as lines are added or removed above them. Lowercase
  marks belong to their file, uppercase ones (`mA`) take you back to their
  file from anywhere; `''` returns to where the last jump left from, `'<`
  and `'>` are the last visual selection, and `:marks` lists them. They
  last until `le` quits;
- registers, as in Vim: `"` and a letter before a yank, delete, change or
  paste uses that register (`"ayy` yanks the line into a, `"ap` pastes
  it, in visual mode too); `"A` (the capital) adds to register a, `"_`
  deletes without keeping the text, `"0` holds the last yank, `"+` and
  `"*` are the clipboard, and `:reg` lists them. Every yank and delete
  still goes to the unnamed register and the clipboard, as before;
- pasting from the terminal (Ctrl+Shift+V in a terminal window, Cmd-V
  over SSH) puts the text in as it is, newlines and indentation included,
  with no auto-indent added: at the cursor in insert mode, before it in
  normal mode, in place of a visual selection, and on one line in a
  prompt. One `u` takes it back;
- replacing across the project, as Spacemacs' projectile: `SPC p R` asks
  for the text and what replaces it (`SPC p %`: a regexp, with `\1` and so
  on in the replacement), then goes to each match in the project's files
  in turn, highlighted, and asks: `y` replaces it, `n` skips it, `!`
  replaces it and all the rest, `.` replaces it and stops, `q` stops. The
  files it changed stay open and unsaved: `:wa` (or `SPC f S`) saves them.
  The project's files are, in a git repository, the ones git sees: what
  `.gitignore` (in any directory), `.git/info/exclude` and your global
  excludes leave out is left alone, and so is `.git`; dotfiles git tracks
  (`.formatter.exs`, `.github/`) are in. `SPC p f` and `SPC /` use the
  same files. For the files git ignores, `SPC s R` (`SPC s %`: a regexp)
  replaces in a directory you name (the file's own, to start with): every
  file under it, ignored and hidden ones included, never `.git`;
- ex commands: `:w :q :wq :e :sp :vsp :s/// :sort :!cmd :r !cmd`;
- the mouse: a click puts the cursor there (and selects that window; on a
  mode line, just the window), a drag selects text as `v` does, and the
  wheel scrolls the window under the pointer three lines. It works in
  Lepton's terminal windows, in `tmux` with `mouse on` (your tmux.conf
  has it), and over SSH from terminals that report the mouse (Terminal
  and iTerm2 on the Mac do).

## A tour: beyond the basics

Try each of these on a practice file. Make it, and open it:

```sh
printf 'apple one\nbanana two\ncherry three\n' > ~/fruit.txt
le ~/fruit.txt
```

After each exercise, `u` (undo, as many times as it takes) brings the file
back for the next one.

### Repeat yourself: macros

`qa` starts recording into register a. Type `I- ` (insert `- ` at the
start of the line), **Esc**, then `j` (down a line), and `q` to stop.
`100@a` plays it a hundred times, but it stops by itself at the last
line, where `j` can't go any further:

```
- apple one
- banana two
- cherry three
```

Macros are saved: quit `le`, start it again, and `@a` is still there.

### Columns: visual block

`gg`, then `C-v` starts a block; `jj` stretches it over three lines.
`I# ` and **Esc** puts `# ` on all three, at the block's column. Undo,
then try `C-v jj $ A;` and **Esc**: `$` reaches each line's end, so `A`
appends `;` to every line. With `w` first, `C-v jj e U` upper-cases the
second word of each line (`ONE`, `TWO`, `THREE`). `d` deletes a block,
`y` copies it and `p` puts it back as a block; on an empty line (after
`o` and **Esc**) a block pastes as lines of its own.

### Keep several things: registers

`"ayy` copies the line into register a; `j"byy` copies the next one into
b. Now `G"ap` and `"bp` paste them at the end, each from its own
register, whatever you copied or deleted in between. `:reg` lists them;
`"A` adds to a, `"_dd` deletes a line without keeping it, and `"+p`
pastes the clipboard.

### Come back: marks

On `banana`, `ma` marks the place. `G` goes to the end; `'a` comes back
to the line (`` `a `` to the very spot), and `''` returns to where you
jumped from. Marks work as motions too: from the last line, `d'a`
deletes up to banana's line. `mA` (a capital) marks a place in this
file that `'A` finds from any other file; `:marks` lists them.

### Find and replace

- In this file: `:%s/a/A/g` replaces every `a`.
- In the whole project: `SPC p R` asks for the text, then its
  replacement, and goes to each match in turn: `y` replaces it, `n`
  skips it, `!` replaces all the rest (in every file), `.` this one and
  stop, `q` stop. `SPC p %` takes a regexp (`\bfoo\b` for the word foo,
  `\1` in the replacement for a group). What `.gitignore` leaves out is
  left alone.
- In a directory, ignored files and all: `SPC s R` (`SPC s %`).
- The files changed stay unsaved: `SPC f S` (or `C-x s`, or `:wa`) saves
  them all.

### Mouse and pasting

In a terminal window (or tmux, or over SSH from your Mac) a click puts
the cursor where you click, a drag selects, and the wheel scrolls.
Ctrl+Shift+V (Cmd-V over SSH) pastes text exactly as you copied it,
indentation and all, and one `u` takes it back.

## Big files and many buffers

`le` keeps a buffer's lines in chunks: an edit copies the chunk it
changes, not the file, and undo's 200 steps share the rest. A 50 MB
file (660,000 lines) opens in a quarter of a second, and typing, `dd`
and `u` stay at a few milliseconds a key; searching all of it takes
about a third of a second. Hundreds of buffers are fine too: with
1,000 files open, keys still take well under a millisecond, and the
buffer list (`SPC b b`) filters as you type.

Word completion in a big file looks at the two megabytes around the
cursor, nearest first, rather than at the whole file.

## Typst

`.typ` files open in Typst mode: headings, `*strong*`, `_emphasis_`,
`#code`, `$math$` and comments are coloured, and with
[Typst](typst.html) installed, saving compiles the file into a PDF
beside it. `SPC m c` compiles (an error: the cursor goes to it),
`SPC m p` compiles and opens the PDF, `SPC m w` turns compiling on save
off and on. `le --typst` (the desktop's Typst Editor) starts a new
document in `~/Documents`.

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
As in Vim, a folded heading counts as one line to commands that work on
whole lines: `dd`, `Vd`, `yy`, `>>` on it take the heading and
everything folded under it (`u` brings it all back).

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
