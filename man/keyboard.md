## DESCRIPTION

Choose the input sources you type with on the desktop (Photon): keyboard
layouts, and Korean. With more than one, Super+Space (or a click on the
classic taskbar's indicator: EN, KO, TH, ...) moves to the next one. The
setting is the system's and is kept across reboots.

The sources:

- `us`: English (US), always the first XKB group, so shortcuts such as
  Ctrl+C keep their keys in every layout.
- `ko`: Korean, the standard 2-set (Dubeolsik) keyboard. Letters compose
  into Hangul syllables as you type, shown underlined until each one is
  done; Backspace takes back one jamo. The Hangul key, Right Alt (a
  Korean keyboard's 한/영 key) or Shift+Space switch between Hangul and
  English (the indicator shows `A`).
- `th` Thai, `hi` Hindi (InScript), `bn` Bengali, `ta` Tamil (InScript),
  `km` Khmer, `lo` Lao, `my` Burmese, `ar` Arabic, `he` Hebrew, `vi`
  Vietnamese: the layouts of xkeyboard-config, as on other Linux
  desktops. At most three besides English.

Korean composes in programs that take composed text (Firefox and other
GTK programs, through Wayland's text-input protocol). In Lepton's own
windows (terminal windows, `le`) the keys stay English: they don't take
composed text yet. The other layouts type in every window, and terminal
windows show their text (Unifont's glyphs, where Terminus has none).

Accents type everywhere, not only on the desktop (the text console,
terminal windows, SSH, tmux, Firefox): Alt and an accent key, then the
letter, as with Option on a Mac. Alt+e acute (Alt+e e: é), Alt+` grave,
Alt+i circumflex, Alt+u umlaut (ü), Alt+n tilde (ñ), Alt+h háček (č),
Alt+, cedilla or ogonek (ç ą), Alt+k ring (å), Alt+m macron (ā), Alt+g
breve (ă), Alt+z dot above (ż), Alt+= double acute (ő). Shift gives the
capital; Space, or the accent key again, the accent alone. One key: Alt+c
ç, Alt+s ß, Alt+l ł, Alt+o ø, Alt+' æ, Alt+q œ, Alt+$ €, Alt+# £, and more
(`keyboard accents`).

## COMMANDS

- `keyboard`: the input sources, with `*` at the one in use.
- `list`: every source there is (`+`: one of yours).
- `use ID`: switch to a source.
- `next`: switch to the next one (as Super+Space does).
- `add ID...`, `remove ID...`: add or remove sources.
- `set ID...`: use exactly these sources.
- `accents`: the accent keys, and whether they are on.
- `accents on`, `accents off`: turn them on or off (off: the Alt keys go
  to programs as they are, for programs that use them). Kept across
  reboots.

## EXAMPLES

    keyboard add ko
    keyboard set us ko th
    keyboard use ko
    keyboard list
    keyboard accents
    keyboard accents off

## SEE ALSO

photon(1), classic(1), firefox(1), https://trylepton.app/docs/accents.html, https://trylepton.app/docs/keyboard.html
