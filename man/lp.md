## DESCRIPTION

Print each FILE (standard input when none is given) on PRINTER, or on
your default printer (see `printers`, `lpoptions`). PDF and JPEG are sent
as they are; plain text is laid out as a PDF. Prints the job's id, as
`request id is office-3 (1 file(s))`, for `lpstat` and `cancel`.

## OPTIONS

- `-d PRINTER`: the printer.
- `-n COPIES`: how many copies.
- `-t TITLE`: the job's title (the file's name by default).
- `-o OPTION`: accepted for compatibility.

## EXAMPLES

    lp notes.txt
    lp -d office -n 2 report.pdf
    ls -l | lp

## SEE ALSO

lpr(1), lpstat(1), cancel(1), printers(1), https://trylepton.app/docs/printing.html
