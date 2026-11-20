## DESCRIPTION

Connect to each HOST and print its SSH host keys as `known_hosts` lines.
Check the fingerprints (with `ssh-keygen -l`) before appending them to
`~/.ssh/known_hosts`.

## OPTIONS

- `-p PORT`: connect to PORT (default 22).
- `-t TYPES`: only these key types, comma-separated (`ed25519`,
  `ecdsa`, `rsa`).
- `-H`: accepted for compatibility.

## EXAMPLES

    ssh-keyscan git.example.com >> ~/.ssh/known_hosts

## SEE ALSO

ssh(1), ssh-keygen(1)
