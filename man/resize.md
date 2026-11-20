## DESCRIPTION

Ask the terminal emulator how big its window is, set the terminal's size
to match, and print the size as `COLUMNS=...; LINES=...;`. Useful on a
serial console, where the size is not reported automatically.

## EXIT STATUS

0 on success, 1 if the terminal did not answer.

## SEE ALSO

stty(1)
