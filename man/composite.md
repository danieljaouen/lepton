## DESCRIPTION

Lay OVERLAY over BASE (where: `-gravity`, `-geometry +X+Y`; how: `-compose`, `-dissolve N`) and write OUTPUT. It's `magick composite`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    composite -gravity southeast logo.png photo.jpg marked.jpg
    composite -dissolve 30 watermark.png photo.jpg out.jpg

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
