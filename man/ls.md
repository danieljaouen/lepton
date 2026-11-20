## DESCRIPTION

List information about each FILE: a directory's contents, or the file
itself. With no FILE, list the current directory. Entries are sorted by
name, ignoring case. Names starting with `.` are hidden unless `-a` or
`-A` is given.

When standard output is a terminal, names are laid out in columns and
coloured by type; when it is a pipe or a file, one name is printed per
line without colour.

## OPTIONS

- `-1`: one entry per line.
- `-a`: show all entries, including hidden ones and `.` and `..`.
- `-A`: show hidden entries but not `.` and `..`.
- `-l`: long format: type and permissions, link count, owner, group,
  size, modification time and name (and a symbolic link's target).
  Directory listings start with a `total` line in KiB.
- `-h`: with `-l`, print sizes in human-readable units (`4.0K`, `1.2M`).
- `-R`: list subdirectories recursively.
- `-r`: reverse the sort order.
- `-t`: sort by modification time, newest first.
- `-S`: sort by size, largest first.
- `-d`: list a directory itself, not its contents.
- `-F`: mark entries by type: `/` directory, `@` symbolic link, `*`
  executable.
- `-G`: colour the output even when it is not a terminal.

## ENVIRONMENT

- `LSCOLORS`: colours in BSD format (11 foreground/background letter
  pairs, as on macOS). The default is `exfxcxdxbxegedabagacad`.
- `NO_COLOR`: when set, never colour (unless `-G` is given).

## EXIT STATUS

0 on success, 2 if a FILE could not be found.

## EXAMPLES

    ls -la
    ls -lhS ~/Downloads
    ls -1 | wc -l

## SEE ALSO

tree(1), find(1), stat(1), du(1)
