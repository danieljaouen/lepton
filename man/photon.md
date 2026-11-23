## DESCRIPTION

Photon is Lepton's graphical desktop: a Wayland compositor that takes
over the display and shows windows you move, resize and type into with
the mouse and keyboard. Its first window is a terminal running your
shell. Run it from the console of a machine with a display; when you
quit, the text console comes back.

For a Windows 95-style desktop with a taskbar and Start menu, run
`classic` instead.

## COMMANDS

- `photon`, `photon start`: start the desktop.
- `term [COMMAND...]`: open a terminal window (running COMMAND instead
  of the shell, if given).
- `info`: the display size, window manager, clients and windows.
- `display extend`, `display mirror`: with two displays, put them side
  by side or show the same picture on both.
- `screenshot FILE.png`: save the screen as a PNG (`screenshot`(1) does
  more: a window, a region, a delay).
- `stop`: quit the desktop.

## KEYS

- `Alt+Enter`: open a terminal window.
- `Alt+Tab`: focus the next window.
- `Alt+F4`: close the window (or click its close button). Closing a terminal
  window ends its shell and everything running in it.
- `Alt+Shift+Right`, `Alt+Shift+Left`: move the window to the next or
  previous display.
- `Ctrl+Shift+V`: paste in a terminal window.
- `Ctrl+=` (or `Ctrl++`), `Ctrl+-`, `Ctrl+0`: in a terminal window, a
  bigger or smaller text size (14 to 32 pixels), or the usual 16 again.
  New terminal windows open at the size chosen last.
- `Print` (or `Super+Shift+3`): save a screenshot of the desktop in
  `~/Pictures`; `Alt+Print` (`Super+Shift+5`): the focused window;
  `Shift+Print` (`Super+Shift+4`): a region you drag, or a window you
  click (Esc cancels). A notice says where it went.
- `Ctrl+Alt+Backspace`: quit.
- Drag a title bar (or Alt+drag anywhere) to move a window; drag the
  bottom-right corner (or Alt+right-drag) to resize it.

Super works in place of Alt.

## ENVIRONMENT

Programs in Photon's windows get `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR`, so Wayland programs such as Firefox can connect.

## SEE ALSO

classic(1), firefox(1), input(1), screenshot(1), https://trylepton.app/docs/desktop.html
