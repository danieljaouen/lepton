## DESCRIPTION

Print the contents of the clipboard: Lepton's, shared by its terminals,
the editor, tmux and the desktop. In UTM it is also your Mac's: text
copied on the Mac is there for `pbpaste` (UTM's Clipboard Sharing, on by
default, which Lepton's SPICE agent talks to). `wl-paste` is the same
command.

## EXAMPLES

    pbpaste > snippet.txt
    pbpaste >> ~/.ssh/authorized_keys     # a public key copied on the Mac

## SEE ALSO

pbcopy(1)
