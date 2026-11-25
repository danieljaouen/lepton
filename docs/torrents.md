---
title: Torrents
order: 14
section: network
summary: Downloading from magnet links and .torrent files with torrent, and sharing back.
---

# Torrents

`torrent` downloads with BitTorrent, from magnet links and `.torrent`
files, and shares what you have back while the torrent stays added.
It's Lepton's own, written in Elixir: nothing to install.

```
torrent add 'magnet:?xt=urn:btih:...'
torrent add ubuntu.iso.torrent
torrent
```

Quote a magnet link: it holds `&`, which the shell would take as "run
in the background". Files go into `~/Downloads` (`-d DIR` chooses
another folder).

`torrent` alone, in a terminal, shows your torrents, updated each
second: how far each has got, its speeds, its peers, the time left.
It's the desktop's Torrents (on the Start menu). `a` adds one there
(paste a magnet link, or type a file or address), Space stops or starts
the one chosen, `d` removes it (`D`: and deletes its files, after a
`y`), `q` quits.

Downloads run in Lepton itself, not in the command: they go on after
`torrent` ends, and after you log out. One that was running when Lepton
restarted starts again the next time you use `torrent`, checking what's
on disk first; nothing is downloaded twice.

<!-- commands: torrent -->

## From Firefox

Click a magnet link in [Firefox](apps.html), or open a `.torrent` file
it downloads: it goes straight to Lepton's Torrents, without asking. The
torrent is added (into `~/Downloads`), a notice on the desktop says so,
and the Torrents window opens (or, if it's open, shows the new one).
`torrent open MAGNET|FILE` does the same from a terminal.

This is Firefox's own setting for those links and files, which Lepton
makes when it starts Firefox; restart Firefox after updating Lepton for
it to apply.

## Where peers come from

- **Trackers**: the servers a torrent names (HTTP, HTTPS and UDP).
- **The DHT**: BitTorrent's network of nodes. A magnet link without
  trackers is found there; so are more peers when there are few.
- **Peers that connect to Lepton**: on port 6881 (or the next free one
  up to 6889). Behind a router, only peers you connect to are reached;
  downloading works the same.
- **`--peer HOST:PORT`**: a peer you know, one on your network, say.

A magnet link carries the torrent's hash but not its list of files: the
first peer that has the list sends it (and its hash must match). Every
piece is checked against its SHA-1 before it's kept; a bad one is
fetched again from someone else.

## Sharing your own files

```
torrent create -t udp://tracker.opentrackr.org:1337/announce ~/Photos/trip
torrent add -d ~/Photos trip.torrent
```

`create` makes a `.torrent` for a file or a folder and prints its
magnet link. Adding it with `-d` set to the folder the files are in
checks them, finds them complete, and shares them (seeding).

## Your list

```
torrent list
torrent stop 1          # its number, the start of its id, or part of its name
torrent start 1
torrent rm 2            # its files stay
torrent rm --delete 2   # its files go too
torrent info file.torrent
```

Each torrent is recorded in `~/.local/state/lepton/torrents/`.
