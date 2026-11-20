## DESCRIPTION

Print STRING (the arguments joined by spaces), or `y` when none are
given, followed by a newline, over and over until the command is
interrupted with Ctrl-C or the reader of the pipe goes away.

## EXAMPLES

    yes | head -3
    yes no | head -2

## SEE ALSO

seq(1), head(1)
