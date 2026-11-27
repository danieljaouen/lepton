---
title: Fuzzy finding (fzf)
order: 3
section: shell
summary: fzf, and its keys in the shell (C-r, C-t, M-c), the Media Player and SNES.
---

# Fuzzy finding: fzf

`fzf` chooses a line from a list by typing parts of it, as junegunn's
[fzf](https://github.com/junegunn/fzf). The letters you type must come in
order but needn't be together: `mdsrc` finds `music/david/source.mp3`.
The best matches are at the bottom, nearest the prompt, and Enter prints
the one chosen:

```sh
fzf                           # a file under here
vim $(fzf)                    # edit it
git branch | fzf | xargs git switch
ps | fzf -m                   # Tab marks several
ls | fzf -f doc               # no screen: just the matches, best first
```

Up and Down choose (or the mouse: a click selects, a double click
chooses, the wheel moves), Esc gives up. The query is fzf's extended
search: words separated by spaces must all match, `'word` matches
exactly, `^word` at the start, `word$` at the end, `!word` leaves lines
out, and `a | b` matches either. A word with a capital letter matches
case.

With nothing piped in, fzf lists the files under the current folder as
fzf does (hidden ones too, without `.git` and `node_modules`), and you
can start typing while they're still being found. `$FZF_DEFAULT_COMMAND`
and `$FZF_DEFAULT_OPTS` are read as fzf reads them.

## In the shell

lsh has fzf's key bindings (the ones `~/.fzf.zsh` gives zsh):

- **C-r**: choose a command from your history, newest first; what you've
  typed starts the search. The command comes back to the prompt, to run
  with Return or change first.
- **C-t**: choose files and folders under here (Tab marks several); they
  go in where the cursor is, quoted as the shell needs.
- **M-c**: choose a folder under here and go to it. Alt+C types ç while
  the accent keys are on (`keyboard accents`), so press Esc, then `c`:
  Esc before a key is Alt with it, as in zsh.

## In the Media Player and SNES

In the Media Player's and SNES's file lists, `/` opens fzf over the
media (or the games) in every folder below. Type parts of a name, and
Enter plays it: in the Media Player, with what comes after it in its
folder, or Tab marks several to play just those.

<!-- commands: fzf -->
