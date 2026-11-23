## DESCRIPTION

Save a screenshot of the desktop (Photon or the classic desktop) as a
PNG file: the whole desktop, the focused window, a region you pick with
the mouse, a rectangle, or one display.

Without FILE, it goes into `~/Pictures` (made if need be), named for the
time: `Screenshot-2026-11-23-153005.png` (`-2`, `-3`, ... when there is
one already). A FILE without an extension gets `.png`. The file is
yours, not root's.

The desktop has keys for the same (they save into `~/Pictures` and show
a notice saying where): Print, or Super+Shift+3, the whole desktop;
Alt+Print, or Super+Shift+5, the focused window; Shift+Print, or
Super+Shift+4, a region.

The pointer isn't in screenshots.

## OPTIONS

- `-w`, `--window`: the focused window, with its title bar and border.
- `-s`, `--select`: pick a region with the mouse: drag a rectangle, or
  click a window to take that window (or the desktop, for that display).
  Esc, or another button, cancels.
- `-g X,Y,WxH`, `--geometry X,Y,WxH`: the rectangle WxH pixels at X,Y
  (cut to the desktop).
- `-D N`, `--display N`: display N (1 is the primary; see `photon
  info`).
- `-d SECONDS`, `--delay SECONDS`: wait first (after picking the region,
  with `-s`): time to open a menu or move a window.

## EXIT STATUS

0 when the screenshot is saved; 1 when the desktop isn't running, there
is no window with the focus, the selection was canceled or the file
can't be written; 2 for a usage error.

## EXAMPLES

    screenshot
    screenshot -w
    screenshot -s ~/bug.png
    screenshot -d 5
    screenshot -g 0,0,800x600 top-left.png
    screenshot -D 2

## SEE ALSO

photon(1), classic(1), https://trylepton.app/docs/desktop.html#screenshots
