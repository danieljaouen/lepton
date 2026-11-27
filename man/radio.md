## DESCRIPTION

Internet radio. In a terminal, `radio` shows your stations, and finds
others: `/` searches Radio Browser's directory (radio-browser.info,
about 50,000 stations) by name, then by genre. The station playing and
the song on it show at the bottom, the song's title changing as the
next one starts. This is the desktop's Radio.

Your stations are kept in `~/.config/lepton/radio`. Until you add one, a
few listener-supported stations are there to try (SomaFM, Radio
Paradise, KEXP, FIP).

`radio STATION` plays one of yours (its name, or the start of it), or an
address, with a status line, until `q`.

Streams are read the way radio players read them (Icecast and SHOUTcast,
with their song titles; playlists; HLS) and decoded by FFmpeg, an app:
`sudo app install ffmpeg`. A stream that drops is opened again.

## COMMANDS

- `radio`: the full-screen radio.
- `radio STATION|URL`: play it.
- `radio list`: your stations, a name and an address a line.
- `radio search WORDS...`: stations Radio Browser knows, the most
  listened to first.
- `radio add NAME URL`: add a station (one of the same name or address
  is replaced).
- `radio rm NAME`: remove one.

## KEYS

- Up, Down (or `k`, `j`): choose; Enter: play.
- Space (or `s`): stop, and play again.
- `/`: search; Enter searches, Esc cancels.
- Tab: your stations, or what the search found.
- `a`: add the station found to yours; `d`: remove one of yours.
- `9`, `0` (or `-`, `+`): the volume; `m`: mute.
- `q`: quit (the radio stops).

The mouse: a click selects a station, a double click plays it, the wheel
moves, and a click on a tab (Your stations, Found) shows it.

The bottom line shows these keys; a message there (a station added,
removed or found) gives way to them after a few seconds.

## EXAMPLES

    radio
    radio groove
    radio search jazz
    radio add "Groove Salad" https://ice2.somafm.com/groovesalad-128-mp3
    radio rm "Groove Salad"

## FILES

- `~/.config/lepton/radio`: your stations, a name, a tab and an address
  a line (`#` starts a comment).

## SEE ALSO

play(1), volume(1), https://trylepton.app/docs/media.html
