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
windows the keys stay English: the terminal's font has no Hangul. The
other layouts type in every window, but the terminal shows only the
scripts its font has.

## COMMANDS

- `keyboard`: the input sources, with `*` at the one in use.
- `list`: every source there is (`+`: one of yours).
- `use ID`: switch to a source.
- `next`: switch to the next one (as Super+Space does).
- `add ID...`, `remove ID...`: add or remove sources.
- `set ID...`: use exactly these sources.

## EXAMPLES

    keyboard add ko
    keyboard set us ko th
    keyboard use ko
    keyboard list

## SEE ALSO

photon(1), classic(1), firefox(1), https://trylepton.app/docs/keyboard.html
