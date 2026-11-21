---
title: Languages and keyboards
order: 13
section: desktop
summary: Type Korean, Thai, Hindi, Arabic and other languages on the desktop. Choose input sources with keyboard, switch with Super+Space, and compose Hangul in Firefox.
---

# Languages and keyboards

The desktop types US English until you add other input sources: a
keyboard layout (Thai, Hindi, Arabic, ...) or Korean. Add them with
`keyboard`:

    keyboard add ko th
    keyboard

```
* us  English (US)
  ko  Korean (Hangul, 2-set)
  th  Thai
Super+Space: the next one.
Korean: the Hangul key, Right Alt or Shift+Space switch between Hangul and English.
```

With more than one, **Super+Space** moves to the next source, and the
classic taskbar shows the one in use (EN, KO, TH, ...) beside the clock:
click it to move to the next. The choice is the system's, and is kept
across reboots.

<!-- commands: keyboard -->

## Sources

| ID | Source |
|---|---|
| `us` | English (US) |
| `ko` | Korean: the 2-set (Dubeolsik) keyboard, composed into Hangul |
| `th` | Thai (Kedmanee) |
| `hi` | Hindi (InScript) |
| `bn` | Bengali |
| `ta` | Tamil (InScript) |
| `km` | Khmer |
| `lo` | Lao |
| `my` | Burmese |
| `ar` | Arabic |
| `he` | Hebrew |
| `vi` | Vietnamese |

The layouts are xkeyboard-config's, the ones other Linux desktops use,
with their plain and Shift characters. You can have up to three besides
English. English stays the first layout, so shortcuts (Ctrl+C, Ctrl+T in
Firefox) are where they always are, whatever you type with.

## Korean

Korean uses the US keys, with the 2-set layout printed on Korean
keyboards: `r` is ㄱ, `k` is ㅏ, and Shift gives the doubled consonants
(`R` is ㄲ) and ㅒ ㅖ. As you type, the jamo compose into a syllable,
shown underlined while it can still change:

| Keys | Text |
|---|---|
| `gks` | 한 |
| `gksrnrdj` | 한국어 |
| `dkssudgktpdy` | 안녕하세요 |

A vowel after a final consonant takes the consonant into the next
syllable, as on any Korean keyboard (`ekfr` is 닭, `ekfrk` is 달가).
Backspace takes back one jamo at a time. Space, Return, punctuation, a
click or another window finish the syllable.

To type English without leaving Korean, press the **Hangul** key, **Right
Alt** (where a Korean keyboard has its 한/영 key) or **Shift+Space**; the
indicator shows `A`. Press it again for Hangul.

Hangul is composed in programs that take composed text: Firefox and other
GTK programs, through Wayland's text-input protocol. In Lepton's own
windows (terminal windows, `le`) the keys type English: they don't take
composed text yet, though they show Korean text. To show Korean pages, Firefox comes with the fonts
(see [Apps](apps.html)).

## In Lepton's own windows

The layouts type in terminal windows too: the shell and `le` get the
characters. Terminal windows, title bars and the taskbar draw with the
built-in Terminus font, and with GNU Unifont's glyphs for what Terminus
lacks: Chinese, Japanese and Korean, Thai, Devanagari, Arabic and the
rest of Unicode's first 65,536 characters. They are bitmaps, one glyph
per character: scripts whose letters join or reorder (Devanagari,
Arabic) show their characters one by one, not shaped as Firefox shows
them.

Chinese, Japanese and Korean characters take two columns, as in other
terminals: the shell's line editor, `le`, `ls` and terminal windows
count them so, and so do terminals you reach Lepton from over SSH.

## Not yet

- Japanese and Chinese input, which needs converting from kana or pinyin
  with a dictionary.
- Layouts' AltGr (third level) characters, and dead keys in Lepton's own
  windows.
- Layouts on the text console (outside the desktop).
