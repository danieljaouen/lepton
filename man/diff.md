## DESCRIPTION

Compare FILE1 and FILE2 line by line and print the differences in
unified format: `---`/`+++` headers, then `@@` hunks with three lines of
context, where lines starting with `-` are only in FILE1 and lines
starting with `+` only in FILE2. On a terminal the output is coloured.

## OPTIONS

- `-u`: unified format (always used).
- `-N`: accepted for compatibility.

## EXIT STATUS

0 if the files are the same, 1 if they differ, 2 on trouble.

## EXAMPLES

    diff -u old.conf new.conf
    diff a.txt b.txt > changes.diff

## SEE ALSO

git(1)
