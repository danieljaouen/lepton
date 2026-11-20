## DESCRIPTION

Print the user ID, group ID and groups of USER (yourself by default),
for example `uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo)`.
Members of the `sudo` group may use `sudo`.

## EXIT STATUS

0 on success, 1 if there is no such user.

## SEE ALSO

whoami(1), useradd(1), sudo(1)
