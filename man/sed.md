## DESCRIPTION

Read each FILE (or standard input), apply the commands in SCRIPT to each
line in turn, and print the result. Commands are separated by `;` or
newlines. Each command may be preceded by an address, and then applies
only to the matching lines:

- `N`: line number N.
- `$`: the last line.
- `/REGEX/`: lines matching REGEX.

The commands are:

- `s/REGEX/REPLACEMENT/FLAGS`: replace the first match of REGEX. In
  REPLACEMENT, `&` is the whole match and `\1` ... `\9` are groups. Any
  character may stand in for `/`. FLAGS: `g` replace every match, `p`
  print the line if a replacement was made, `I` ignore case.
- `d`: delete the line (do not print it).
- `p`: print the line (again).
- `q`: print the line and stop.

Regular expressions use the extended syntax: `(...)`, `|`, `+` and `?`
are operators, and `\d`, `\w`, `\s` and `\b` work.

## OPTIONS

- `-n`: print only what `p` and the `p` flag print.
- `-e SCRIPT`: give the script as an option.
- `-i`: edit the FILEs in place instead of printing.
- `-E`: accepted for compatibility (expressions are always extended).

## EXAMPLES

    sed 's/colour/color/g' essay.txt
    sed -i 's/^#\s*//' config.toml
    sed -n '/error/p' build.log
    sed '1d;$d' table.txt

## SEE ALSO

grep(1), awk(1), tr(1), le(1)
