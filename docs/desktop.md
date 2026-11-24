---
title: The desktop (Photon)
order: 12
section: desktop
summary: Photon, Lepton's Wayland compositor, and the classic desktop: windows on the display, with the mouse and keyboard.
---

# The desktop (Photon)

Photon is Lepton's graphical desktop: a Wayland compositor written in
Elixir, like the rest of Lepton. It takes over the VM's display and shows
windows that you move, resize and type into with the mouse and keyboard.
The first window is a terminal running your shell.

```sh
photon
```

Run it from the console in the VM window (UTM's display, or QEMU with a
display). It needs the display's framebuffer, so it doesn't start from
`mix lepton.shell` on a Mac or over a serial console without a display.

When you quit, the text console comes back as you left it.

## Keys and the mouse

| Key or action | What it does |
|---|---|
| Alt+Return | open a terminal window |
| Alt+Tab | focus the next window |
| Alt+F4, or the × button | close the window |
| Alt+Shift+Right / Left | move the window to the next / previous [display](usb.html) |
| Super+Space | the next input source: keyboard layout or Korean ([Languages and keyboards](keyboard.html)) |
| the volume keys | mute, quieter, louder ([Sound](sound.html)) |
| Print, or Super+Shift+3 | [screenshot](#screenshots) of the whole desktop |
| Alt+Print, or Super+Shift+5 | screenshot of the focused window |
| Shift+Print, or Super+Shift+4 | screenshot of a region: drag it, or click a window |
| Ctrl+Alt+Backspace | quit Photon |
| click a window | focus it and bring it to the front |
| drag the title bar (or Alt+drag anywhere) | move the window |
| drag the bottom-right corner (or Alt+right-drag) | resize the window |

Super (the Windows/Command key) works in place of Alt where the VM passes
it through.

## Terminal windows

A terminal window runs `lsh` with your account, as your console does.
Everything that works in a terminal works there, including `le`, `tmux`
and the colours of your prompt. Resizing a window changes its rows and
columns. Typing `exit` closes the window. Closing the window ends its
shell and everything running in it, as closing a terminal does on Unix:
close the System Monitor and its `top` stops too. Apps such as Firefox
keep running. **Ctrl+Shift+V** pastes the clipboard. In the shell, pasted
lines go into the command line and wait for Return; programs that
don't ask for pastes (bracketed paste) get each newline as Return, as
in other terminals. **Shift+Enter** starts a new line in the command
instead of running it (Return runs them all), as Alt+Enter does; Claude
Code takes it the same way.

The text size changes as in Firefox: **Ctrl+=** (or **Ctrl++**) makes
it bigger and **Ctrl+-** smaller, through the sizes of the Terminus font
(14 to 32 pixels high), and **Ctrl+0** goes back to the usual 16. The
window keeps its size and holds fewer (or more) rows and columns, which
programs in it are told, as when you resize it.

Programs that ask for the mouse get it: in `le`, a click moves the
cursor, a drag selects and the wheel scrolls. New terminal windows
open at the size you chose last, until Lepton restarts.

## Opening files

`open` (also `xdg-open`, as your dotfiles call it on Linux) opens files,
folders and web addresses in the app for them:

| What | Opens in |
|---|---|
| text: notes, code, configuration, any file that is UTF-8 text | `le`, in the terminal you ran `open` in |
| images (PNG, JPEG, GIF, WebP, SVG, ...) and PDFs | [Firefox](apps.html) |
| a folder, such as `open .` | Firefox, as a list of its files |
| a web address (`https://...`) | Firefox |

```sh
open notes.txt          # edit it in le
open photo.jpg paper.pdf
open .                  # the current folder, in Firefox
xdg-open https://trylepton.app
```

Firefox needs the desktop (`photon` or `classic`). If Firefox is
already open, each page, image, PDF or folder opens in a new tab of it,
`open .` too. Several files can be
given at once: the text files open together in one `le`, and everything
else opens in Firefox. `open` recognises a file by its contents as well
as its name, so an image without an extension still opens in Firefox.
Files that are neither text nor anything Firefox shows (programs,
archives) aren't opened.

## The clipboard

Photon's windows share Lepton's clipboard, the one `pbcopy` and
`pbpaste`, tmux's copy mode and the editor's yanks use (see
[System](system.html#clipboard)):

- Copy in Firefox (Ctrl+C), then `pbpaste` in a terminal, **Ctrl+Shift+V**
  in a terminal window, `C-t ]` in tmux or `p` in `le`.
- Copy in a terminal (`echo hello | pbcopy`, a tmux or editor copy), then
  Ctrl+V in Firefox.

Only text reaches Lepton's clipboard; anything else a program copies
goes only to programs on the desktop.

## Drag and drop

Programs can drag things within their windows and between them: in
Firefox, drag a tab along the tab bar to move it. No picture of what's
dragged follows the pointer.

From a shell, inside Photon or on the console:

```sh
photon term                 # open another terminal window
photon term le notes.txt    # a window running a command
photon info                 # the display, clients and windows
photon display mirror       # with two displays: mirror them (or extend)
photon stop                 # quit
```

## Screenshots

**Print** saves a screenshot of the whole desktop in `~/Pictures`, named
for the time (`Screenshot-2026-11-23-153005.png`), and a notice at the
top right says where it went. **Alt+Print** takes just the focused
window, with its title bar, and **Shift+Print** lets you pick a region:
drag a rectangle, or click a window to take that window (Esc cancels).
Without a Print key (a Mac's keyboard), **Super+Shift+3**, **4** and
**5** do the same, as on a Mac: whole desktop, region, window. In UTM,
macOS keeps Command+Shift+3 and 4 for itself unless UTM captures the
keyboard; the `screenshot` command works either way.

From a shell, `screenshot` does the same, with a delay and a file name
if you want them:

```sh
screenshot                  # the whole desktop, into ~/Pictures
screenshot -w               # the focused window
screenshot -s shot.png      # pick a region (or click a window), save it as shot.png
screenshot -d 5             # wait five seconds first (to open a menu, say)
screenshot -g 0,0,800x600   # a rectangle: X,Y,WIDTHxHEIGHT
screenshot -D 2             # the second display
```

Screenshots are PNG files, and are yours (not root's), like any file
you make. The pointer and the screenshot notice are left out.

<!-- commands: screenshot -->

## The classic desktop

For something more familiar, type `classic` instead of `photon`. It's
Photon with a different window manager, styled after Windows 95:

- grey 3D window frames with a navy title bar and **minimize**,
  **maximize** and **close** buttons (double-click a title bar to
  maximize or restore); fullscreen (a video's fullscreen button in
  Firefox, or F11) fills the whole display, over the taskbar, until you
  leave it (Esc)
- a teal desktop with icons for [Firefox](apps.html), the Terminal, the
  Text Editor (`le`), the System Monitor (`top`),
  [Passwords](passwords.html) and **Install PostgreSQL** (which sets up
  the [database](postgresql.html) and becomes **PostgreSQL**, opening
  `psql`), and one for each
  [USB drive or SD card](storage.html) that is mounted: double-click one
  to open it
- a **taskbar** with a button for each window (click to bring it to the
  front, click again to minimize it), the Wi-Fi signal (click it to pick
  a network: [Wi-Fi](networking.html#on-the-classic-desktop)), the
  Bluetooth rune (click it for your devices: [Bluetooth](bluetooth.html)), the
  volume's speaker (click it for the volume control: [Sound](sound.html)),
  the emoji picker (below) and a clock
- the **Start** menu (click Start, or Ctrl+Esc): [Firefox](apps.html),
  Terminal, Text Editor, System Monitor, [Printers](printing.html) (choose
  your default printer), [Passwords](passwords.html) (the password
  manager), Help and Exit Desktop

### Emoji

Click the yellow smiley beside the clock for the emoji picker: a tab
for each category (smileys, people, nature, food, activities, travel,
objects, symbols) and a grid of emoji. Point at one to see its code
point; click it to type it into the window you were using, as many as
you like. Clicking the smiley again, or anywhere else, closes it.

Firefox's text fields and Lepton's terminal windows take the emoji as
typed. When a window can't take text from the desktop, the emoji goes
to the clipboard instead (the picker says so), to paste with Ctrl+V.
Firefox draws emoji in colour; terminals in black and white, two cells
wide.

The keys from the table above work here too. Exit Desktop (or
Ctrl+Alt+Backspace) returns you to the console. Lepton never starts a
desktop at boot; you choose `photon` or `classic` when you want one.

## More than one display

With a second display (a second VM display, or a USB display adapter),
the desktop extends across both, side by side, or mirrors the primary
display (`photon display mirror`). Displays can come and go while it
runs. See [USB, hubs and displays](usb.html).

Keyboards and mice plugged in while the desktop runs, directly or
through a hub, work within a second.

## Wayland

Photon speaks the standard Wayland protocol on
`$XDG_RUNTIME_DIR/wayland-0` (`/run/user/UID`). It supports the core
protocol and `xdg-shell`:

| Interface | Version | Notes |
|---|---|---|
| `wl_compositor`, `wl_surface`, `wl_region` | 4 | |
| `wl_shm`, `wl_shm_pool`, `wl_buffer` | 1 | ARGB8888 and XRGB8888, shown opaque |
| `wl_seat`, `wl_pointer`, `wl_keyboard` | 5 | US keymap (XKB), key repeat info |
| `wl_output` | 2 | |
| `xdg_wm_base`, `xdg_surface`, `xdg_toplevel`, `xdg_popup` | 1 | |
| `wl_subcompositor`, `wl_subsurface` | 1 | |
| `wl_data_device_manager`, `wl_data_source`, `wl_data_offer` | 3 | the clipboard (shared with Lepton's), drag and drop |
| `org_kde_kwin_server_decoration_manager` | 1 | Photon draws the title bars |
| `lepton_shm` | 1 | Lepton's own programs: shared memory by path |

Inside Photon, terminals set `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`, so
a Wayland program that draws with shared-memory buffers can connect to
it; [Firefox](apps.html) does. Photon draws the title bar and border
itself and tells GTK so (KDE's server-side decoration protocol), so GTK
programs leave theirs out.

## What it doesn't do yet

- GPU-drawn (EGL) programs, transparency, the primary selection (pasting
  what's selected with the middle button), touch, and HiDPI scaling.
- Fonts other than the built-in 8x16 Terminus bitmap font and, for what
  it lacks (Chinese, Japanese, Korean, ...), GNU Unifont's bitmaps.
- Japanese and Chinese input ([other languages](keyboard.html) and
  Korean work).
- Video drivers: programs draw with the CPU.
- Arranging displays other than left to right, or changing a display's
  resolution. Wayland programs see one output, the whole desktop.

<!-- commands: photon classic open -->
