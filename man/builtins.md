## DESCRIPTION

Builtin commands run inside the shell, `lsh`, rather than as programs
of their own, because most of them change the shell itself: its
directory, variables, aliases or jobs. `man NAME` shows one of them;
`type NAME` says whether a name is a builtin, an alias or a command.

## BUILTINS

- `cd [DIR | -]`: change the current directory to DIR, to your home
  directory when DIR is left out, or back to the previous directory
  with `-` (which is printed). `PWD` and `OLDPWD` are updated.
- `pwd`: print the current directory.
- `pushd DIR`: change to DIR, remembering the current directory on the
  directory stack, then print the stack.
- `popd`: change back to the directory on top of the directory stack,
  removing it from the stack.
- `dirs`: print the current directory and the directory stack.
- `export [NAME[=VALUE]...]`: set environment variables, which commands
  started by the shell see. A NAME without a value is set to the empty
  string if it is not set already. With no arguments, print every
  variable.
- `local [NAME[=VALUE]...]`: the same as `export` (lsh has no
  functions).
- `unset NAME...`: remove variables.
- `alias [NAME[=VALUE]...]`: define aliases, words replaced by VALUE
  when they start a command (`alias ll='ls -l'`). `alias NAME` prints
  one alias; with no arguments, print them all, including those from
  `~/.zshrc` and `/etc/lshrc`.
- `unalias [-a] NAME...`: remove aliases (all of them with `-a`).
- `history [N]`: print the command history (the last N commands).
- `exit [N]`, `logout [N]`: leave the shell with status N (by default
  the status of the last command). In a terminal window this closes the
  window.
- `source FILE [ARG...]`, `. FILE [ARG...]`: run the commands in FILE in
  this shell, so the variables, aliases and directory it sets stay set.
  ARGs become `$1`, `$2`, ... while it runs.
- `jobs`: list the background and stopped jobs with their numbers.
- `fg [%N]`: bring job N (the latest by default) to the foreground.
- `bg [%N]`: let a stopped job N carry on in the background.
- `wait`: wait until every background job has finished.
- `type NAME...`: say what NAME is: an alias, a shell builtin or a
  command.
- `which NAME...`: print the path of command NAME (or what it is, for
  an alias or builtin).
- `read [-p PROMPT] [-r] [NAME...]`: read a line from standard input
  and split it into words, setting each NAME to one word and the last
  NAME to the rest of the line (`REPLY` when no NAME is given). `-p`
  prints PROMPT first. Returns 1 at the end of input.
- `eval ARG...`: run the ARGs, joined by spaces, as a shell command.
- `shift [N]`: drop the first N (1) positional parameters, so `$2`
  becomes `$1`.
- `set [--] [ARG...]`: with ARGs, set the positional parameters `$1`,
  `$2`, ...; with no arguments, print the variables. `set -o` prints
  the shell's options. Shell options such as `set -e` are not
  supported.
- `setopt NAME...`, `unsetopt NAME...`: turn shell options on or off,
  as in zsh.
- `bindkey`: list the line editor's key bindings.
- `exec COMMAND [ARG...]`, `command COMMAND [ARG...]`: run COMMAND,
  ignoring aliases. (`exec` does not end the shell.)
- `builtin COMMAND [ARG...]`: run the version of COMMAND that ships with
  Lepton, even when an official update installed with `lpm upgrade`
  stands in for it.
- `break [N]`, `continue [N]`: leave the innermost loop (or N loops), or
  go on with its next round.
- `hash`, `rehash`, `umask`, `return`: accepted for compatibility with
  zsh and bash scripts; they do nothing.

## SEE ALSO

lsh(1), help(1), test(1), https://trylepton.app/docs/shell.html
