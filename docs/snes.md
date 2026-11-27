---
title: SNES games
order: 17
section: desktop
summary: The SNES emulator (snes): Super Nintendo games from .sfc and .smc files, in a window on the desktop.
---

# SNES games

`snes` plays Super Nintendo (Super Famicom) games from ROM files,
`.sfc` or `.smc`, in a window on the desktop:

```sh
snes "Super Game.sfc"
open "Super Game.sfc"     # the same, from anywhere (and from Firefox's downloads)
snes                      # choose a game from your files
```

On the [classic desktop](desktop.html), **SNES** is on the Start menu
and the desktop: it lists your folders and games to choose from
(Enter or a double click plays one, Backspace goes up a folder, the
mouse wheel scrolls, `/` finds a game in any folder below by typing parts
of its name, as [fzf](fzf.html) does, and q quits).

The emulation is [bsnes](https://github.com/bsnes-emu/bsnes)'s: accurate
to the cycle, with the cartridges' enhancement chips (Super FX, SA-1 and
others), at full speed. It's the `snes` app, installed the first
time you need it: `snes` and the desktop's SNES ask, or run
`sudo app install snes` (about 5 MB to download, 22 MB installed).
Lepton draws the pictures, as for the [media player](media.html). The
game's sound plays through the same mixer as Firefox's, at the system
volume (or in Bluetooth headphones), so other sound goes on playing
while a game runs.

## Keys

The pad is read by the keys' places, so it's the same on every keyboard
layout:

| SNES | Keyboard |
|---|---|
| D-pad | arrow keys |
| A, B | X, Z |
| X, Y | S, A |
| L, R | Q, W |
| Start | Enter |
| Select | Right Shift (or Backspace) |

And for the emulator:

| Key | Does |
|---|---|
| P (or Pause) | pause, and go on |
| Ctrl+R | reset the console |
| F5, F9 | save the game's state, load it back |
| 1 to 9 | choose the state's slot first (slot 1 to start with) |
| F11 (or a double click) | full screen, and back |
| Esc | close |

## Saves

A game's own saves (the cartridge's battery RAM) are kept in
`~/.local/share/snes`, as `GAME.srm`, written a couple of seconds after
the game saves and again when you close it, so you can go on where you
left off. Save states (F5) go beside them, `GAME.state1` to
`GAME.state9`: a snapshot of the whole console, at any moment.

## Game controllers

USB and Bluetooth gamepads work, two at once for two players: the first
one plugged in is player 1 (along with the keyboard), the second player
2. Plug one in during a game and the title says which player it is.

The buttons go by their place, as on a SNES pad, whatever is printed on
them: the bottom face button is B, the right one A, the left one Y and
the top one X; the shoulder buttons (and triggers) are L and R; Select
and Start are Select and Start. The D-pad, or the left stick, moves.
The USB pads made to look like a SNES pad work as they're laid out.

## Limits

The games themselves are yours to bring: Lepton doesn't come with any.

<!-- commands: snes -->
