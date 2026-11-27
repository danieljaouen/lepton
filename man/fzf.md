## DESCRIPTION

A fuzzy finder, as junegunn's fzf. `fzf` reads lines from a pipe (or,
with nothing piped in, takes the files under the current folder), shows
them full screen, and narrows them as you type: the letters you type must
come in order, not together, so `mdsrc` finds `music/david/source.mp3`.
The best matches are at the bottom, nearest the prompt. Enter prints the
line chosen; Esc prints nothing.

    vim $(fzf)
    git branch | fzf | xargs git switch

The query is fzf's extended search:

- `word`: fuzzy; words separated by spaces must all match.
- `'word`: exactly this text. `^word`: at the start. `word$`: at the end.
- `!word`: leaves out the lines that have it.
- `a | b`: either.

A word with a capital letter in it is matched with case, one without
ignores it (smart case). Matches are ranked as fzf ranks them: letters
at the start of a word (after `/`, `-`, `_`, a space ...) and letters
that come together count most, then shorter lines.

Files are found as fzf's own walker finds them: hidden ones included,
`.git` and `node_modules` left out, symbolic links not followed into.
`$FZF_DEFAULT_COMMAND`, if set, is run for the list instead, and
`$FZF_DEFAULT_OPTS` holds options that come before the ones given.

The shell has fzf's key bindings: `C-r` chooses a line from history,
`C-t` puts in files and folders, `M-c` (Esc, then `c`) goes to a folder.
See lsh(1).

## KEYS

- Typing narrows; Backspace, `C-u` (all), `C-w` (a word) take back;
  Left, Right, `C-a`, `C-e` move in the query.
- Up and Down (or `C-p`/`C-k`, `C-n`/`C-j`), Page Up, Page Down: choose.
- Tab (with `-m`): mark this line too and go on; Shift+Tab: mark and go
  back. Enter then prints the marked lines.
- Enter: choose. Esc, `C-c`, `C-g`: give up (exit status 130).
- The mouse: a click selects a line, a double click chooses it, the
  wheel moves.

## OPTIONS

- `-m`, `--multi`: Tab marks several lines.
- `-q QUERY`, `--query=QUERY`: start with this query.
- `-e`, `--exact`: words match exactly (`'word` is fuzzy then).
- `-i`: ignore case; `+i`: match case; `--smart-case` (the default).
- `--reverse`, `--layout=reverse`: the prompt at the top, the best match
  under it.
- `--prompt=STR` (`> `), `--header=STR`: the prompt, and a line under it.
- `--tac`: the last line first. `--no-sort`, `+s`: keep the lines in their
  order. `--tiebreak=index`, `--scheme=history`: equal matches in their
  order, not by length.
- `-1`, `--select-1`: with only one match, choose it without asking.
  `-0`, `--exit-0`: with none, quit without asking.
- `--print-query`: print the query first. `--print0`: end lines with NUL.
- `-f QUERY`, `--filter=QUERY`: no screen; print the lines that match,
  best first.

fzf's other options (`--height`, `--preview`, `--bind`, `--color`, ...)
are accepted and change nothing: the list always fills the screen.

## EXIT STATUS

0 when a line was chosen (or `-f` found some), 1 when none matched, 2 for
an error, 130 when you gave up.

## EXAMPLES

    fzf                              # a file under here
    vim "$(fzf -q .md$)"
    ps | fzf --header='a process' -m
    cat ~/.lsh_history | fzf --tac --no-sort
    ls | fzf -f doc                  # without the screen

## SEE ALSO

lsh(1), grep(1), find(1), https://github.com/junegunn/fzf
