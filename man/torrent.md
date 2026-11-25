## DESCRIPTION

Download with BitTorrent, from magnet links and `.torrent` files, and
share back what you have while the torrent stays added (seeding).

Downloads run in Lepton itself: they go on after the command ends, and
after you log out. In a terminal, `torrent` shows yours, with their
progress, speeds and peers, updated each second (this is the desktop's
Torrents). Torrents that were running start again the next time you use
`torrent` (after a restart, say), checking what's already on disk first.

Peers come from the trackers a torrent names (HTTP, HTTPS and UDP), from
the DHT (for magnet links without trackers, or when peers are few), and
from peers that connect to Lepton (on port 6881, or the next free one up
to 6889). A magnet link's list of files comes from the first peer that
has it. Every piece is checked (SHA-1) before it's kept.

## COMMANDS

- `torrent`: the list, updated live (in a terminal); else as `list`.
- `torrent add [-d DIR] [--peer HOST:PORT] MAGNET|FILE|URL...`: add a
  torrent: a magnet link (quote it: it holds `&`), a `.torrent` file, or
  the address of one. Files go into DIR (default `~/Downloads`).
  `--peer` names a peer to try (one on your network, say).
- `torrent list`: each torrent, its number, id, progress and state.
- `torrent stop T`, `torrent start T`: stop one (it stays listed), start
  it again. T is its number in the list, the start of its id, or part
  of its name.
- `torrent rm [--delete] T`: remove one; with `--delete`, its files too.
- `torrent info FILE`: what a `.torrent` file holds, and its magnet link.
- `torrent create [-o FILE] [-t TRACKER]... PATH`: make a `.torrent` for
  a file or folder (FILE: `PATH.torrent` by default), and print its
  magnet link. Add it to share it: `torrent add -d PARENT FILE`.

## KEYS

- Up, Down (or `k`, `j`): choose.
- `a`: add (paste a magnet link, or type a file or address; Enter).
- Space: stop or start the one chosen.
- `d`: remove it (its files stay); `D`: remove it and delete its files
  (after a `y`).
- `o`: its folder.
- `q`: quit (the downloads go on).

## EXAMPLES

    torrent add 'magnet:?xt=urn:btih:...'
    torrent add -d ~/Videos debian.iso.torrent
    torrent
    torrent stop 1
    torrent rm --delete 2
    torrent create -t udp://tracker.opentrackr.org:1337/announce ~/Photos/trip

## FILES

- `~/.local/state/lepton/torrents/`: your torrents: a `.torrent` (or,
  until its file list arrives, a `.magnet`) and a `.json` each.
- `~/Downloads`: where files go by default.

## SEE ALSO

play(1), https://trylepton.app/docs/torrents.html
