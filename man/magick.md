## DESCRIPTION

ImageMagick 7: read images, change them, write them. `magick INPUT
OPTIONS... OUTPUT` applies the options in order; the output's name picks
its format (`.png`, `.jpg`, `.webp`, `.tif`, ...), or a prefix does
(`png:-`, standard output). `magick TOOL ...` runs one of its tools,
which are also commands of their own: convert(1), identify(1),
mogrify(1), composite(1), montage(1), compare(1).

It's the `imagemagick` app (`sudo app install imagemagick`; the commands
offer to install it). It runs as you, in this folder; Ctrl-C stops it.
PNG, JPEG, GIF, WebP, TIFF, BMP, JPEG XL, JPEG 2000, PDF, PostScript and
more are read and written; SVG and HEIC are read. PDF goes through
Ghostscript (`-density DPI` before a PDF or SVG sets how finely it's
drawn; `paper.pdf[0]` is its first page). Text is drawn in DejaVu.

## OPTIONS

A few of hundreds (`magick -help`, and https://imagemagick.org/script/command-line-options.php):

- `-crop WxH+X+Y`, then `+repage`: cut out a rectangle. `-gravity center -crop 1:1`: the middle square.
- `-trim`: cut off a plain border. `-shave WxH`: from every side.
- `-resize WxH` (fit), `WxH!` (exactly), `50%`. `-thumbnail`: resize and strip.
- `-rotate DEGREES`, `-auto-orient`, `-flip`, `-flop`.
- `-quality N`, `-strip`, `-colorspace Gray`, `-blur 0xS`, `-brightness-contrast BxC`.
- `-annotate +X+Y TEXT` (with `-fill`, `-pointsize`, `-gravity`, `-font`).

## EXAMPLES

    magick photo.jpg -crop 800x600+100+50 +repage cropped.jpg
    magick photo.jpg -resize 50% -quality 85 half.jpg
    magick IMG_0042.HEIC photo.jpg
    magick -density 150 paper.pdf[0] page1.png
    magick logo.svg logo.png
    magick scan1.jpg scan2.jpg scans.pdf
    magick photo.jpg -gravity center -crop 1:1 +repage -resize 512x512 avatar.png

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).
1 if the app isn't installed.

## SEE ALSO

convert(1), identify(1), mogrify(1), composite(1), montage(1), compare(1), open(1), https://trylepton.app/docs/images.html
