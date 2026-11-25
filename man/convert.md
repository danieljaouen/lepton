## DESCRIPTION

ImageMagick's convert: read INPUT, apply the options in order, write OUTPUT (its name picks the format). It's `magick convert`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    convert photo.png -resize 50% photo.jpg
    convert photo.jpg -crop 400x300+10+10 +repage part.jpg

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
