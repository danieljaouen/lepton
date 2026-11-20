## DESCRIPTION

Read words (separated by white space) from standard input and run CMD
with them added as arguments. CMD defaults to `echo`. All words are
passed to one run of CMD unless `-n` limits the number.

## OPTIONS

- `-n N`: pass at most N words to each run of CMD.
- `-I STRING`: replace STRING in CMD's arguments with the words instead
  of adding them at the end. Combine with `-n 1` to run CMD once per
  word.

## EXIT STATUS

The highest exit status of the runs of CMD.

## EXAMPLES

    find . -name '*.tmp' | xargs rm
    ls *.wav | xargs -n 1 play
    cat hosts | xargs -n 1 -I {} ping -c 1 {}

## SEE ALSO

find(1), lsh(1)
