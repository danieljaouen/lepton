---
title: Editing images
order: 18
section: desktop
summary: ImageMagick (magick, convert, identify, mogrify): crop, resize, rotate and convert images from the command line.
---

# Editing images

Lepton edits images with [ImageMagick](https://imagemagick.org) 7: `magick`,
and its tools as commands of their own (`convert`, `identify`, `mogrify`,
`composite`, `montage`, `compare`). It's the `imagemagick` app, installed
the first time you use one of them (it asks), or with
`sudo app install imagemagick` (about 46 MB to download, 140 MB
installed, 60 MB of it Ghostscript, for PDF).

It reads and writes PNG, JPEG, GIF, WebP, TIFF, BMP, JPEG XL, JPEG 2000,
PDF, PostScript and dozens more, and reads SVG and HEIC (iPhone photos).
To look at the result, `open` it (Firefox shows images and PDFs).
(Installed before SVG and PDF came in? The next `magick` fetches them
for the one after; `sudo app update imagemagick` brings them now.)

## Crop

```sh
magick photo.jpg -crop 800x600+100+50 +repage cropped.jpg   # 800x600, from 100 across and 50 down
magick photo.jpg -gravity center -crop 1:1 +repage square.jpg  # the middle square
magick photo.jpg -gravity center -crop 80%x80%+0+0 +repage zoomed.jpg
magick scan.png -trim +repage trimmed.png                    # cut off the plain border
magick photo.jpg -shave 20x20 shaved.jpg                    # 20 pixels off every side
```

`+repage` forgets where the cut came from, so the new image starts at
0,0 (without it, some formats keep the old canvas).

## Resize, rotate, flip

```sh
magick photo.jpg -resize 1024x1024 smaller.jpg    # fit within 1024x1024, keeping its shape
magick photo.jpg -resize 50% half.jpg
magick photo.jpg -resize 640x480! stretched.jpg   # exactly, shape or not
magick photo.jpg -thumbnail 200x200^ -gravity center -extent 200x200 thumb.jpg
magick photo.jpg -rotate 90 turned.jpg
magick photo.jpg -auto-orient upright.jpg         # as the camera held it (EXIF)
magick photo.jpg -flop mirrored.jpg               # left to right (-flip: top to bottom)
```

## Convert and adjust

```sh
magick IMG_0042.HEIC photo.jpg                    # iPhone photo to JPEG
magick -density 300 logo.svg -resize 512x512 logo.png   # SVG, drawn sharp at any size
magick -density 150 paper.pdf[0] page1.png        # a PDF's first page as an image
magick scan1.jpg scan2.jpg scans.pdf              # images into one PDF
magick photo.png -quality 85 photo.jpg
magick photo.jpg -strip clean.jpg                 # without its metadata (location too)
magick photo.jpg -colorspace Gray grey.jpg
magick photo.jpg -brightness-contrast 10x15 brighter.jpg
magick photo.jpg -blur 0x3 soft.jpg
magick photo.jpg -fill white -pointsize 36 -gravity south -annotate +0+20 'Lepton' captioned.jpg
```

## Many at once

`mogrify` changes images in place, or writes them beside the originals
in another format with `-format`:

```sh
mogrify -resize 1600x1600 -quality 85 *.jpg      # in place: keep copies first
mogrify -format webp *.png                        # photo.png -> photo.webp beside it
mogrify -path small -thumbnail 300x300 *.jpg      # into the folder small
```

## Look, combine, compare

```sh
identify photo.jpg                                # format, size, colours
identify -format '%wx%h\n' *.jpg
montage *.jpg -tile 4x -geometry 200x200+4+4 sheet.jpg   # a contact sheet
composite -gravity southeast logo.png photo.jpg marked.jpg
compare -metric AE a.png b.png diff.png           # the number of pixels that differ
```

An image can go to standard output, to pipe on: `magick photo.jpg png:-`.
Text is drawn in DejaVu (Sans, Serif, Mono; ImageMagick's Helvetica,
Arial, Times and Courier are those too).

<!-- commands: magick convert identify mogrify composite montage compare -->
