## DESCRIPTION

Print FILE (or standard input), collapsing each run of identical
adjacent lines into one. Repeated lines that are not next to each other
are not detected, so input is usually sorted first.

## OPTIONS

- `-c`: prefix each line with the number of times it occurred.
- `-d`: print only lines that are repeated.
- `-u`: print only lines that are not repeated.
- `-i`: ignore case when comparing.

## EXAMPLES

    sort words.txt | uniq -c | sort -rn | head

## SEE ALSO

sort(1), wc(1)
