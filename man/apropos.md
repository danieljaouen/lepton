## DESCRIPTION

Search the manual pages: list the pages whose name or one-line summary
contains a KEYWORD, each with its summary. Upper and lower case are the
same, and a KEYWORD may hold spaces when quoted (`apropos "caps lock"`).
With several keywords, a page that matches any of them is listed (`-a`:
all of them).

With `-t`, the pages' text is searched as well, for what a summary
doesn't mention: a page found only in its text is listed with the words
around the first match on the next line (cut to the terminal's width).

`man -k KEYWORD` is the same search.

## OPTIONS

- `-a`, `--and`: list only pages that match every KEYWORD.
- `-t`, `--text`: search the whole text of each page too.

## EXIT STATUS

0 when something matched, 16 when nothing did, 2 for a usage error.

## EXAMPLES

    apropos disk
    apropos -a disk usb
    apropos -t "caps lock"
    apropos -t loadkeys

## SEE ALSO

man(1), whatis(1), help(1)
