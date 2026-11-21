## DESCRIPTION

`lsh` is Lepton's shell: the command language you type at every prompt
and write scripts in. It also answers to `sh`, `zsh` and `bash`.

- With no arguments on a terminal, start an interactive shell.
- With `-c COMMANDS`, run COMMANDS (the remaining ARGs become `$0`,
  `$1`, ...).
- With SCRIPT, run the commands in that file with ARGs as `$1`, `$2`,
  ...
- With no arguments and no terminal, run the commands read from
  standard input.

## LINE EDITING

Emacs-style keys, as in oh-my-zsh: `C-a`/`C-e` start and end of line,
`C-b`/`C-f` and `M-b`/`M-f` move, `C-k` and `C-u` kill, `C-w` kills a
word, `C-y` yanks, `C-r` searches history, `Tab` completes commands and
paths, `C-x C-e` edits the line in `$EDITOR`, `C-l` clears the screen.
A dim suggestion from history is accepted with Right, `C-f` or `C-e`.
Each command name (the first, and each after `|`, `&&`, `||` or `;`)
turns green when it exists and red when it does not.
`bindkey` lists every binding.

## SYNTAX

- Pipelines and lists: `a | b`, `a && b`, `a || b`, `a; b`, `a &` (in
  the background), `{ a; b; }` and `( a; b )`.
- Redirection: `>`, `>>`, `<`, `2>`, `2>&1`, `&>`, `&>>`.
- Quoting: `'single'` (literal), `"double"` (with `$` expansion), `\`.
- Expansion: `$VAR`, `${VAR}`, `$?`, `$$`, `$!`, `$#`, `$@`, `$1`...,
  `~`, `$(command)`, backquotes, `$((arithmetic))` and globs (`*`, `?`,
  `[...]`).
- Control: `if ...; then ...; elif ...; else ...; fi`, `for X in ...;
  do ...; done`, `while ...; do ...; done`, `until ...`, `break [N]`,
  `continue [N]`.
- Assignment: `NAME=value`, and `NAME=value command` for one command.

## JOB CONTROL

`C-c` interrupts the foreground job and `C-z` suspends it. `jobs`, `fg`,
`bg`, `wait` and `kill` manage jobs. Closing a terminal window ends
its shell and everything started from it.

## STARTUP FILES

- `/etc/lshrc`: system-wide aliases (oh-my-zsh's `git` plugin).
- `~/.zshrc`: imported, not executed: its `alias`, simple `export` and
  `setopt` lines are applied, and macOS-only branches are skipped.
- `~/.lshrc.exs`: Elixir run at startup, for example to register
  commands with `Lepton.Commands.register/2`.
- `~/.config/starship.toml`: the prompt (a starship engine).
- `~/.lsh_history`: the history, appended after every command.

## EXIT STATUS

The status of the last command run.

## EXAMPLES

    lsh -c 'echo $1' x hello
    lsh backup.sh ~/notes

## SEE ALSO

builtins(1), test(1), keys(1), https://trylepton.app/docs/shell.html
