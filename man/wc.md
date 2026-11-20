## DESCRIPTION

Print the number of lines, words and bytes in each FILE (or in standard
input), and a total line when there are several FILEs. A word is a run
of characters between white space.

## OPTIONS

- `-l`: print the line count.
- `-w`: print the word count.
- `-c`: print the byte count.
- `-m`: print the character count.

Given any of these, only the counts asked for are printed, in the order
lines, words, bytes, characters.

## EXAMPLES

    wc notes.txt
    ls | wc -l

## SEE ALSO

grep(1), cat(1)
