## DESCRIPTION

Put images side by side on one: a contact sheet (`-tile COLSx`, `-geometry WxH+GAP+GAP`, `-label`). It's `magick montage`: ImageMagick 7 (the `imagemagick` app; see magick(1)),
run as you, in this folder.

## EXAMPLES

    montage *.jpg -tile 4x -geometry 200x200+4+4 sheet.jpg

## EXIT STATUS

ImageMagick's: 0 on success, 1 on an error (said on standard error).

## SEE ALSO

magick(1), https://trylepton.app/docs/images.html
