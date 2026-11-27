## DESCRIPTION

Play a Super Nintendo (Super Famicom) game from its ROM file (`.sfc`,
`.smc`) in a window on the desktop. Without a ROM, choose one from your
files: Enter (or a double click) plays a game or opens a folder,
Backspace goes up, a click selects, the wheel scrolls, `/` finds a game
in any folder below by typing parts of its name (fzf(1)), `q` quits.
This is what the desktop's SNES (Start menu and icon) opens.

The emulation is bsnes's (the `snes` app: `sudo app install snes`;
`snes` offers to install it when it's missing). It needs the desktop
(`photon` or `classic`).

## KEYS

- Arrow keys: the D-pad. X: A. Z: B. S: X. A: Y. Q: L. W: R.
- Enter: Start. Right Shift or Backspace: Select.
- P or Pause: pause and go on. Ctrl+R: reset.
- F5: save the state; F9: load it. 1 to 9: choose the slot first.
- F11 or a double click: full screen. Esc: close.

Keys are read by their places on the keyboard: the same on every layout.

## GAME CONTROLLERS

USB and Bluetooth gamepads: the first plugged in is player 1 (with the
keyboard), the second player 2; they're found when plugged in, during a
game too. Buttons go by place, as on a SNES pad: bottom B, right A, left
Y, top X; shoulders and triggers L and R; Select, Start. The D-pad or
the left stick moves. SNES-style USB pads (joysticks with numbered
buttons) work as laid out.

## FILES

- `~/.local/share/snes/GAME.srm`: the game's own saves (its battery
  RAM), written when they change and on closing.
- `~/.local/share/snes/GAME.state1` ... `GAME.state9`: save states.
- `~/.cache/lepton/snes.log`: the emulator's messages.

## EXAMPLES

    snes "Super Game (USA).sfc"
    open game.smc
    snes

## EXIT STATUS

0 when the window is closed. 1 if the ROM doesn't exist, the app isn't
installed, there's no desktop, or the game couldn't start. 2 for a bad
option.

## SEE ALSO

open(1), fzf(1), app(1), https://trylepton.app/docs/snes.html
