---
title: Firefox and other apps
order: 14
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

Firefox runs as you: as your account's user ID, with its profile in your
home (`~/.config/mozilla`). You don't need `sudo`, and Firefox refuses to
run as root in your home anyway. `sudo firefox` runs it as root, with
root's own profile in `/root`.

## What gets installed

`app install firefox` reads the package index of
[Alpine Linux](https://alpinelinux.org/) 3.24, follows Firefox's
dependencies (GTK, fonts, and so on: about 85 packages), downloads them
over HTTPS (about 130 MB) and unpacks them into
`/var/lib/lepton/apps/firefox` (about 350 MB). Then it does the setup the
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

## What's different from Firefox elsewhere

- It draws with the CPU: the VM has no GPU, and the GPU drivers are
  not installed.
- Video plays in the formats Firefox decodes itself (WebM, VP9, AV1),
  but not H.264: the FFmpeg codecs are left out to keep the download small.
- Fonts are DejaVu, which has no Chinese, Japanese or Korean characters.
- There is no clipboard between Firefox and other windows yet.

<!-- commands: app firefox -->
