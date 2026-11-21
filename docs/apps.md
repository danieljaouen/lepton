---
title: Firefox and other apps
order: 17
section: desktop
summary: Firefox, installed on demand from Alpine Linux's packages and run on the desktop.
---

# Firefox and other apps

Lepton's own programs are written in Elixir. For a full web browser it
runs the real thing: **Firefox**, the build Alpine Linux makes for
aarch64, installed the first time you ask for it.

## Starting Firefox

On the [desktop](desktop.html):

- in the **classic desktop**, double-click the **Firefox** icon or choose
  **Firefox** in the Start menu
- in any terminal window, type `firefox` (or `firefox https://example.com`)

The first time, a terminal window shows Firefox being installed, then
Firefox opens. Installing needs root, so as your own user the window asks
for your password (`sudo`). You can also install it ahead of time:

```sh
sudo app install firefox
```

Firefox runs on Photon, Lepton's Wayland compositor, so it needs the
desktop (`photon` or `classic`). It shows Photon's window frame instead of
drawing its own. Its output goes to `~/.cache/lepton/firefox.log`.

Once Firefox is running, `firefox URL`, and [`open`](desktop.html#opening-files)
for a page, image, PDF or folder, opens a new tab in it instead of
starting another Firefox. Firefox passes these on over a D-Bus session
bus, which Lepton starts with Firefox (at `$XDG_RUNTIME_DIR/bus`) and
stops when it closes. A Firefox installed before the bus came with it
gets `dbus` with its next update. If a Firefox started without the bus
is still open, `firefox URL` says so: close it and start it again.

Firefox runs as you: as your account's user ID, with its profile in your
home (`~/.config/mozilla`). You don't need `sudo`, and Firefox refuses to
run as root in your home anyway. `sudo firefox` runs it as root, with
root's own profile in `/root`.

## What gets installed

`app install firefox` reads the package index of
[Alpine Linux](https://alpinelinux.org/) 3.24, follows Firefox's
dependencies (GTK, fonts, FFmpeg's video decoders, and so on: about 121
packages), downloads them over HTTPS (about 266 MB) and unpacks them into
`/var/lib/lepton/apps/firefox` (about 572 MB). Then it does the setup the
packages' install scripts would: GSettings schemas, the MIME database and
image loaders. Nothing outside that directory changes, and
`sudo app remove firefox` removes it all.

On an installed system the app is kept on the data partition. On the live
ISO it is kept in memory and is gone after a reboot; give the VM at least
4 GB of memory to install and run Firefox there.

| Command | What it does |
|---|---|
| `app` | the apps there are, their versions, and when they were last checked for updates |
| `sudo app install NAME` | download and install an app |
| `sudo app update [NAME]` | update an app (or all of them) now |
| `sudo app remove NAME` | remove it |
| `firefox [URL...]` | start Firefox (installing it first, as root) |

The other apps are ones Lepton runs in the background rather than
opening in a window: `bluetooth`, [Bluetooth](bluetooth.html)'s programs
(BlueZ, D-Bus and bluez-alsa: 37 packages, about 8 MB to download), and
`postgresql`, the [PostgreSQL](postgresql.html) database server (26
packages, about 18 MB to download, 49 MB installed), which
`sudo postgresql setup` installs and starts; and `mix-tools`, the
programs `mix` runs: git, for git dependencies, and inotifywait, for
Phoenix's live reload (about 10 MB). They are on the path of `mix`
only; at the prompt, `git` is still Lepton's own.

## Updates

Firefox keeps itself up to date. Alpine rebuilds it for every Firefox
release, about every four weeks, and sooner for security fixes. Every
10 days, starting Firefox also checks for a newer build. If there is one,
Lepton downloads it in the background, next to the one you're using. The
next time you start Firefox, the new version takes over before the window
opens. If its setup fails, the old version stays.

To update right away, close Firefox and run `sudo app update firefox`.
If Firefox is running, the update waits for its next start. Firefox's own
updater is turned off in Alpine's build, so these are the only updates.

Alpine updates Firefox only in its current release, so when Alpine makes
a new stable release (about twice a year), a new Lepton release moves to
it.

When a Lepton release adds packages to Firefox (as when FFmpeg was added
for H.264 video, or the fonts for Asian languages), Firefox doesn't wait for the 10 days: its next start
downloads them in the background, and the start after that uses them.
`sudo app update firefox`, with Firefox closed, does it at once.

If Firefox is broken or won't start, `sudo app reinstall firefox`, with
Firefox closed, downloads and sets up all of its packages again. Your
profile (bookmarks, history, logins) is in your home and stays as it
is.

## What's different from Firefox elsewhere

- **Print** lists Lepton's [printers](printing.html), and prints to them.
- It uses Lepton's [proxy](proxy.html), when one is set: Firefox is
  started with `http_proxy` and `https_proxy` pointing at Lepton, which
  takes each connection through the chain (restart Firefox after
  changing it).

- It draws with the CPU: the VM has no GPU, and the GPU drivers are
  not installed.
- Video plays in every common format: WebM, VP9 and AV1 with Firefox's
  own decoders, and MP4 (H.264 video, AAC sound: TikTok, LinkedIn,
  Instagram and many news sites) through Alpine's FFmpeg, which comes with
  Firefox. The CPU decodes it, so a large video can stutter in a small
  VM. OpenH264, the H.264 plugin Firefox downloads by itself, is turned off:
  Mozilla's build of it needs glibc, so on Lepton it crashed ("gmpopenh264
  crashed") whenever a page used it. Video calls use VP8 or VP9 instead.
- Fonts cover the world's common scripts: DejaVu for Latin, Greek and
  Cyrillic; Noto Sans and Serif CJK for Chinese (Simplified and
  Traditional), Japanese and Korean; Droid's non-Latin fonts for Thai,
  Hindi and other Devanagari languages, Tamil, Arabic, Hebrew, Georgian,
  Armenian and Ethiopic; and Noto for Bengali, Khmer, Lao and Myanmar.
  These are most of the download's size (about 105 MB). A page in a script
  none of them has (Sinhala, Telugu or Tibetan, for example) shows boxes
  for its letters.
- Its clipboard is Lepton's: copy in Firefox and `pbpaste` (or
  Ctrl+Shift+V in a terminal window), or `pbcopy` and paste in Firefox.
  See [The desktop](desktop.html#the-clipboard).
- When memory runs short, it unloads tabs you haven't used for a while,
  and if that isn't enough, Lepton stops the largest tab (it shows as
  crashed; reload it). See [When memory runs out](system.html#when-memory-runs-out).
- Drag a tab along the tab bar to move it (drop it onto another tab to
  group them, or at the far left to pin it).

If Firefox hangs, or its window closes but it doesn't finish quitting,
starting it again stops what was left behind (it would otherwise say
it's already running) and opens a fresh window.

Firefox plays sound on the [sound card](sound.html) Lepton plays on, at
the system volume. Set the volume with `volume`, the volume keys or the
classic desktop's speaker.

<!-- commands: app firefox -->
