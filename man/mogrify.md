## DESCRIPTION

Change images in place (keep copies first), or with `-format` write each in another format beside it, or with `-path DIR` into DIR. It's `magick mogrify`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    mogrify -resize 1600x1600 -quality 85 *.jpg
    mogrify -format webp *.png
    mogrify -path thumbs -thumbnail 300x300 *.jpg

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
