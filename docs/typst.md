---
title: Typst
order: 19
section: shell
summary: Typesetting with Typst (typst compile, watch): documents, papers and slides as PDFs.
---

# Typst

[Typst](https://typst.app) is a typesetting system: you write a
document in its markup, and `typst compile` turns it into a PDF.
Headings, math, tables, figures, bibliographies and its package
universe all work.

It's an [app](apps.html), installed once, as root (about 18 MB):

```
sudo app install typst
```

Or just open the Typst Editor, or run `typst`: without it, they ask
whether to install it, and do, with your password. Then, as yourself:

```
le paper.typ                 # write it (le knows .typ files)
typst compile paper.typ      # paper.pdf
typst watch paper.typ        # compile again on every save; Ctrl-C stops
open paper.pdf               # look at it (in Firefox, on the desktop)
```

A first document:

```
#set page(paper: "a4")
#set text(font: "New Computer Modern")

= A Title

Euler's identity: $e^(i pi) + 1 = 0$.

#table(columns: 2, [*OS*], [*Runtime*], [Lepton], [the BEAM])
```

<!-- commands: typst -->

## The Typst Editor

On the classic desktop, **Typst Editor** (on the Start menu, and an
icon) opens `le` on a new `~/Documents/untitled.typ`, begun with a few
lines; `le --typst` does the same in a terminal, and `le paper.typ`
opens one you have. In Typst files:

| Key | What it does |
|---|---|
| `:w`, `SPC f s` | save, and compile it into a PDF beside it |
| `SPC m c` | compile; on an error, go to it (typst's report: the `*typst*` buffer, `SPC b b`) |
| `SPC m p` | compile and open the PDF (Firefox, on the desktop) |
| `SPC m w` | compile on save, or not |

The markup is coloured: headings, `*strong*` and `_emphasis_`, `#code`
(its keywords apart), `$math$`, labels and references, comments. Keep
the PDF open in Firefox beside the editor and reload it (F5) after a
save.

## Fonts and packages

Typst's own fonts are built in: Libertinus Serif (its default), New
Computer Modern and DejaVu Sans Mono. Put others in
`~/.local/share/fonts` (or `~/.fonts`); if [Firefox](apps.html) is
installed, its fonts are there too, among them Noto for Chinese,
Japanese and Korean. `typst fonts` lists them all.

Packages come from Typst's universe the first time a document imports
one (`#import "@preview/cetz:0.3.4": canvas`), and are kept in
`~/.cache/typst`. Templates too: `typst init @preview/charged-ieee`.

## Updates

`sudo app update typst` (or `sudo app update-all`, every app at once)
gets Alpine's newest build; `typst update` isn't for this one.
