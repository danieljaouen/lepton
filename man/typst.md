## DESCRIPTION

Typst, the typesetting system: write a document in Typst's markup
(`.typ`), and `typst compile` makes a PDF (or PNG, SVG, HTML) of it.
It's the real `typst` program, an app: `sudo app install typst` installs
it (about 18 MB). It runs as you, in the current folder; Ctrl-C stops it.

All of typst's commands work: run `typst --help`, or `typst help
COMMAND`, for each one's options.

Fonts: Typst's own are built in (Libertinus Serif, New Computer Modern,
DejaVu Sans Mono). It also uses yours, in `~/.local/share/fonts` and
`~/.fonts`, and, if Firefox is installed, Firefox's (DejaVu, and Noto
for Chinese, Japanese, Korean and other scripts). `typst fonts` lists
what it finds.

Packages (`#import "@preview/cetz:0.3.4"`) are downloaded the first time
a document uses them, into `~/.cache/typst`.

## COMMANDS

- `typst compile FILE.typ [OUT]`: make a PDF (`OUT.png`, `.svg`,
  `.html`: those formats; `{p}` in OUT numbers the pages).
- `typst watch FILE.typ [OUT]`: compile again whenever the document or
  a file it uses changes, until Ctrl-C.
- `typst init @preview/TEMPLATE [DIR]`: start a document from a
  template.
- `typst query FILE.typ SELECTOR`: what a document holds (its headings,
  its labels...).
- `typst fonts`: the fonts it can use.
- `typst update`: not on Lepton: `sudo app update typst` updates it.

## EXAMPLES

    typst compile paper.typ
    typst compile --format png slides.typ 'slides-{p}.png'
    typst watch thesis.typ
    typst init @preview/charged-ieee report

## SEE ALSO

app(1), le(1), https://typst.app/docs/, https://trylepton.app/docs/typst.html
