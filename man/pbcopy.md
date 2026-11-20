## DESCRIPTION

Copy standard input to the clipboard: the one shared by Lepton's
terminals, the editor, tmux's copy mode and the desktop. The text is
also sent to the terminal emulator you are connected through (with the
OSC 52 escape sequence), so on a serial console or over SSH it can reach
your own computer's clipboard too, if your terminal allows it.

The names `xclip`, `xsel` and `wl-copy` run this command too, so
dotfiles written for Linux or macOS work unchanged.

## OPTIONS

- `-o`: print the clipboard instead (like `pbpaste`).

## EXAMPLES

    pwd | pbcopy
    pbcopy < ~/.ssh/id_ed25519.pub

## SEE ALSO

pbpaste(1)
