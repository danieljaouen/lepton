## DESCRIPTION

Compare two images: how different they are (`-metric AE`: the number of pixels; `RMSE`, `PSNR`, ...), and an image of where, if named. Exits 1 when they differ. It's `magick compare`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    compare -metric AE a.png b.png diff.png

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
