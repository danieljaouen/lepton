## DESCRIPTION

Change your password: you are asked for the current one, then for the
new one twice. root may set anyone's password (`sudo passwd USER`)
without the current one. Passwords are stored only as salted
PBKDF2-SHA512 hashes.

## OPTIONS

- `--stdin`: read the new password from standard input (root only, for
  scripts).

## SEE ALSO

useradd(1), sudo(1), su(1)
