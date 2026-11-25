## DESCRIPTION

Open files, folders and web addresses in the app for them:

- text (by its name, or any file that is UTF-8 text): `le`, in this
  terminal. Without a terminal, on the desktop, `le` opens in a terminal
  window of its own.
- images (PNG, JPEG, GIF, WebP, SVG, BMP, ICO, AVIF) and PDFs: Firefox.
- a folder: Firefox, which lists its files.
- a web address (`http:`, `https:`, `file:`, `ftp:`): Firefox.
- videos and music (MP4, MKV, WebM, MPEG, MP3, FLAC, ...): the Media
  Player, in a window of its own on the desktop (`play`, the video in its
  window); without the desktop, `play` in this terminal.
- `.torrent` files and `magnet:` links: Torrents (`torrent open`: added,
  and the Torrents window opened on the desktop).

A file is recognised by its contents as well as its name, so an image
without an extension still opens in Firefox. With several arguments, the
text files open together in one `le`, and everything else opens in
Firefox. Firefox needs the desktop (`photon` or `classic`), and is
installed the first time, as with `firefox`. If Firefox is already
running, everything opens in new tabs of it, `open .` included.

`xdg-open` is the same command, as Linux and the dotfiles call it.

## EXAMPLES

    open notes.txt
    open photo.jpg paper.pdf
    open holiday.mp4
    open ubuntu.iso.torrent
    open .
    xdg-open https://trylepton.app

## EXIT STATUS

0 if everything was opened. 1 if a file doesn't exist, isn't a kind
`open` knows, or its app couldn't start. 2 without arguments.

## SEE ALSO

le(1), firefox(1), play(1), torrent(1), https://trylepton.app/docs/desktop.html#opening-files
