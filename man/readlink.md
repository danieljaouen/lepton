## DESCRIPTION

Print the target of each symbolic link FILE, exactly as stored.

## OPTIONS

- `-f`: follow every link in turn and print the final absolute path. A
  FILE that is not a link is printed as an absolute path.

## EXIT STATUS

0 on success, 1 if a FILE (without `-f`) is not a symbolic link.

## SEE ALSO

ln(1), realpath(1)
