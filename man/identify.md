## DESCRIPTION

Describe images: format, size, colour depth, file size. `-format` chooses what (`%w`, `%h`, `%m`, `%f`, ...), `-verbose` says everything. It's `magick identify`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    identify photo.jpg
    identify -format '%f: %wx%h\n' *.jpg

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
