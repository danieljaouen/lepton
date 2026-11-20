## DESCRIPTION

Play each WAV FILE in turn on the sound card, at the current volume.
Ctrl-C stops playing.

## EXIT STATUS

0 when everything played, 1 if a file could not be played, 130 if
stopped with Ctrl-C.

## BUGS

Only WAV files are supported. While Firefox is playing sound, the
device may be in use.

## SEE ALSO

beep(1), volume(1), sound(1)
