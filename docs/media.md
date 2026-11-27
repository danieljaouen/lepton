---
title: Videos, music and radio
order: 16
section: desktop
summary: The media player (play) for videos and music, and internet radio (radio), on the desktop and in a terminal.
---

# Videos, music and radio

Lepton plays videos and music with `play`, and internet radio with
`radio`. Both are on the classic desktop's Start menu (Media Player,
Radio) and its icons, and both work in a plain terminal too.

## FFmpeg, once

FFmpeg does the decoding: it reads nearly every format there is (MP4,
MKV, WebM, MOV and AVI; MP3, AAC, FLAC, Ogg, Opus and WAV; HLS streams).
It's an [app](apps.html), installed once, as root:

```
sudo app install ffmpeg
```

Or just open the Media Player or the Radio (or run `play` or `radio`):
without FFmpeg, they ask whether to install it, and do, with your
password. That's 110 packages from Alpine Linux, about 47 MB to download (110 MB
installed). FFmpeg turns files into sound and pictures; Lepton does the
rest itself: the sound goes to the sound card through Lepton's
[sound](sound.html) (so the system volume and the card you chose apply),
and the pictures are drawn into a window on the desktop.

## Videos and music: play

```
play movie.mp4
play ~/Music/album
play --start 1:30 talk.webm
```

On the desktop, a video opens in a window, with a bar under it: the
position, a progress line to click, the volume. In a terminal (or for
music), a line shows what plays:

```
▶ [2/12] Nina Simone - Feeling Good  1:12 / 2:57 [========------------] vol 60%
```

Several files play one after another; a folder plays the media in it.
`play` alone, in a terminal, lists the folders and media files where
you are (or in `~/Videos`, or `~/Music`): Enter (or a double click)
plays one and those after it, a click selects, the wheel scrolls. `/`
finds media in every folder below by typing parts of a name, as
[fzf](fzf.html) does; Tab there marks several to play. That's what the
Start menu's Media Player opens.

<!-- commands: play -->

The keys, in the terminal and in the window:

| Key | What it does |
|---|---|
| Space | pause, play again |
| Left, Right | 5 seconds back or on |
| Up, Down | a minute on or back |
| `9`, `0` | the volume down or up (`m` mutes) |
| `n`, `p` | the next or previous file (terminal) |
| `f`, double click | fill the screen (window; Esc returns) |
| `q`, Esc | stop (in the window: close it) |

A click on the picture pauses; a click on the progress line goes there.
When a video ends, its window stays, on its last picture: Space (or a
click) plays it again; closing the window ends it, and `play` goes on to
the next file. `open video.mp4` opens a video (or music) in the Media
Player too.

## Internet radio: radio

`radio`, in a terminal (or Radio, on the Start menu), shows your
stations; a few listener-supported ones are there to begin with. Enter
plays one; the song playing shows at the bottom, and changes as the next
starts. Space stops it, and plays again.

`/` searches [Radio Browser](https://www.radio-browser.info)'s directory
of about 50,000 stations, by name and by genre: try `jazz`, `bbc` or
`lofi`. Tab switches between your stations and what was found; `a` adds
the one chosen to yours, `d` removes one of yours. The mouse works too: a
click selects a station, a double click plays it, the wheel scrolls, and
a click on a tab shows it. What happened shows
on the bottom line for a few seconds, then the keys are back.

From the command line:

```
radio groove                  # play one of yours (the start of its name)
radio search ambient          # what Radio Browser knows
radio add "Groove Salad" https://ice2.somafm.com/groovesalad-128-mp3
radio rm "Groove Salad"
radio list
```

<!-- commands: radio -->

Your stations are in `~/.config/lepton/radio`, a name, a tab and an
address a line; edit it as you like.

A station's stream is read the way radio players read it, asking for
the titles that come with it (SHOUTcast and Icecast send each song's as
it starts). Playlists (`.pls`, `.m3u`) and HLS streams work too. If a
stream drops, `radio` opens it again.

## When something doesn't play

- "FFmpeg isn't installed": `sudo app install ffmpeg`.
- "no sound card": the pictures still play, without sound. In a virtual
  machine, add a sound device (see [Sound](sound.html)).
- "is in use": another program (Firefox, say) has the sound card. Stop
  it there.
- Anything else: FFmpeg's words about it are in
  `~/.cache/lepton/ffmpeg.log`.
