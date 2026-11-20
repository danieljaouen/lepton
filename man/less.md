## DESCRIPTION

Show FILE (or standard input) one screen at a time. When the output is
not a terminal, the text is simply copied to it.

## KEYS

- `j`, `Enter`, `Down`, `Ctrl-N`, `Ctrl-E`: down one line.
- `k`, `Up`, `Ctrl-P`, `Ctrl-Y`: up one line.
- `Space`, `f`, `Ctrl-F`, `Ctrl-V`, `Page Down`: down one screen.
- `b`, `Ctrl-B`, `Alt-V`, `Page Up`: up one screen.
- `d`, `Ctrl-D`: down half a screen.
- `u`, `Ctrl-U`: up half a screen.
- `g`, `<`, `Home`: go to the top.
- `G`, `>`, `End`: go to the end.
- `/REGEX`: search forward; matches are highlighted.
- `n`, `N`: go to the next or previous match.
- `q`, `Esc`, `Ctrl-C`: quit.

## EXAMPLES

    less /var/log/messages
    dmesg | less

## SEE ALSO

cat(1), head(1), tail(1), man(1)
