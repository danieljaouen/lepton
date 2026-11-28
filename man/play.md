## DESCRIPTION

Play videos and music: files, folders, playlists (`.m3u`, `.pls`) and
addresses (`https://...`, HLS streams). On the desktop, a video opens in
a window of its own; in a terminal, a line shows what plays and where it
is. Several files play one after another (a folder: the media in it).

FFmpeg decodes (it's an app: `sudo app install ffmpeg` installs it, about
47 MB). WAV files need no FFmpeg: when every file is one, Lepton plays
them itself, one after another, at the current volume (Ctrl-C stops). Lepton plays the sound itself, on the sound card `volume` sets
(the system volume applies), and draws the pictures itself. Nearly any
format plays: MP4, MKV, WebM, MOV, AVI; MP3, AAC, FLAC, Ogg, Opus, WAV.

With no files and a terminal, `play` lists the folders and media in the
current folder (or `~/Videos`, or `~/Music`) to choose from: Enter (or a
double click) plays a file and those after it, or opens a folder;
Backspace goes up; a click selects and the wheel scrolls. `/` finds media
in every folder below by typing parts of the name (fzf(1)); Tab there
marks several to play just those. This is the desktop's Media Player.

## OPTIONS

- `--no-video` (`-n`): the sound only, no window.
- `--start TIME` (`-s`): start TIME into the first file: seconds,
  `M:SS` or `H:MM:SS`.

## KEYS

In the terminal and in the window:

- Space: pause, play again.
- Left, Right: 5 seconds back or on; Up, Down: a minute.
- `9`, `0` (or `-`, `+`): the volume (the system's); `m`: mute.
- `n`, `p`: the next or previous file (terminal).
- `q`, Esc: stop (in the window: close it).

In the window, also: `f` or a double click fills the screen (Esc
returns); a click on the picture pauses; a click on the bar's progress
line goes there. In a virtual machine the picture is at most 768x672,
black around it.

## EXAMPLES

    play movie.mp4
    play ~/Music/album
    play --start 1:30 talk.webm
    play --no-video concert.mkv
    play https://example.com/stream.m3u8

## EXIT STATUS

0 when everything played, 1 if a file couldn't be played, 2 for a
mistake in the command, 130 if WAV files were stopped with Ctrl-C.

## FILES

- `~/.cache/lepton/ffmpeg.log`: what FFmpeg said about files it couldn't
  play.

## SEE ALSO

radio(1), fzf(1), volume(1), beep(1), sound(1), app(1), https://trylepton.app/docs/media.html
