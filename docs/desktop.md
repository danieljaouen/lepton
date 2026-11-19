---
title: The desktop (Photon)
order: 12
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
| the volume keys | mute, quieter, louder ([Sound](sound.html)) |
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
columns. Typing `exit` closes the window, and closing the window ends its
shell.

From a shell, inside Photon or on the console:

```sh
photon term                 # open another terminal window
photon term le notes.txt    # a window running a command
photon info                 # the display, clients and windows
photon display mirror       # with two displays: mirror them (or extend)
photon screenshot shot.png  # save the screen as a PNG
photon stop                 # quit
```

## The classic desktop

For something more familiar, type `classic` instead of `photon`. It's
Photon with a different window manager, styled after Windows 95:

- grey 3D window frames with a navy title bar and **minimize**,
  **maximize** and **close** buttons (double-click a title bar to
  maximize or restore)
- a teal desktop with icons for [Firefox](apps.html), the Terminal, the
  Text Editor (`le`) and the System Monitor (`top`), and one for each
  [USB drive or SD card](storage.html) that is mounted: double-click one
  to open it
- a **taskbar** with a button for each window (click to bring it to the
  front, click again to minimize it), the Wi-Fi signal (click it to pick
  a network: [Wi-Fi](networking.html#on-the-classic-desktop)), the
  volume's speaker (click it for the volume control: [Sound](sound.html))
  and a clock
- the **Start** menu (click Start, or Ctrl+Esc): [Firefox](apps.html),
  Terminal, Text Editor, System Monitor, Help and Exit Desktop

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
| `wl_data_device_manager` | 3 | no clipboard yet |
| `org_kde_kwin_server_decoration_manager` | 1 | Photon draws the title bars |
| `lepton_shm` | 1 | Lepton's own programs: shared memory by path |

Inside Photon, terminals set `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`, so
a Wayland program that draws with shared-memory buffers can connect to
it; [Firefox](apps.html) does. Photon draws the title bar and border
itself and tells GTK so (KDE's server-side decoration protocol), so GTK
programs leave theirs out.

## What it doesn't do yet

- GPU-drawn (EGL) programs, transparency, clipboard and drag and drop,
  touch, and HiDPI scaling.
- Fonts other than the built-in 8x16 Terminus bitmap font.
- Keyboard layouts other than US.
- Video drivers: programs draw with the CPU.
- Arranging displays other than left to right, or changing a display's
  resolution. Wayland programs see one output, the whole desktop.

<!-- commands: photon classic -->
