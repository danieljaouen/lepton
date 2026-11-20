## DESCRIPTION

Copy each FILE to standard output, one after the other. With no FILE, or
when FILE is `-`, read standard input.

## OPTIONS

- `-n`: number the output lines (numbering continues across files).

## EXIT STATUS

0 on success, 1 if a FILE could not be read (the other files are still
printed).

## EXAMPLES

    cat notes.txt
    cat header.txt - footer.txt < body.txt > page.txt
    cat -n script.exs

## SEE ALSO

less(1), head(1), tail(1), tac(1), tee(1)
