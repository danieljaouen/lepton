## DESCRIPTION

Search each FILE (standard input when none is given) for lines matching
PATTERN, and print them. When more than one file is searched, each line
is prefixed with its file name. On a terminal, file names, line numbers
and matches are coloured.

PATTERN is a basic regular expression, as in POSIX `grep`: `.`, `*`,
`[...]`, `^` and `$` are special, while `\(`, `\)`, `\|`, `\+`, `\?`
and `\{...\}` are the grouping, alternation and repetition operators.
With `-E` it is an extended regular expression, in which `(`, `)`, `|`,
`+`, `?` and `{...}` are operators without the backslash. Escapes such
as `\d`, `\w`, `\s` and `\b` also work.

## OPTIONS

- `-e PATTERN`: use PATTERN (useful when it starts with `-`).
- `-E`: PATTERN is an extended regular expression.
- `-F`: PATTERN is a fixed string, not a regular expression.
- `-i`: ignore case.
- `-v`: select the lines that do not match.
- `-w`: match whole words only.
- `-n`: prefix each line with its line number.
- `-c`: print only a count of matching lines for each file.
- `-l`: print only the names of files with a match.
- `-o`: print only the matching parts, one per line.
- `-q`: print nothing; only set the exit status.
- `-r`, `-R`: search directories recursively (the current directory
  when no FILE is given), skipping `.git` directories.
- `-H`: always print file names.
- `-h`: never print file names.
- `-s`: do not let unreadable files affect the exit status.

## EXIT STATUS

0 if a line matched, 1 if none did, 2 if a file could not be read.

## EXAMPLES

    grep -n TODO lib/*.ex
    grep -ri 'wifi' ~/notes
    ps | grep -v grep | grep top
    grep -E '^(error|warning):' build.log

## SEE ALSO

sed(1), awk(1), find(1), less(1)
