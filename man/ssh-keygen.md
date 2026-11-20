## DESCRIPTION

Create an ed25519 key pair in OpenSSH format: the private key in FILE
(`~/.ssh/id_ed25519` by default), readable only by you, and the public
key in FILE`.pub`. You are asked before an existing key is overwritten.
Add the public key to GitHub with `gh ssh-key add`, or to a server's
`~/.ssh/authorized_keys`.

The other forms show a key's fingerprint or public key, or forget a
host.

## OPTIONS

- `-t ed25519`: the key type (only ed25519 can be generated).
- `-f FILE`: the key file to create or read.
- `-C COMMENT`: the comment stored with the key (default
  `root@HOSTNAME`).
- `-N ""`: an empty passphrase (passphrases are not supported).
- `-q`: quiet.
- `-l -f FILE`: print the fingerprint of the key in FILE.
- `-y -f FILE`: print the public key of the private key in FILE.
- `-R HOST`: remove HOST from `~/.ssh/known_hosts` (or from FILE with
  `-f`), for example after the server was reinstalled.

## EXAMPLES

    ssh-keygen
    ssh-keygen -C "me@lepton" -f ~/.ssh/work_ed25519
    ssh-keygen -l -f ~/.ssh/id_ed25519
    ssh-keygen -R git.example.com

## SEE ALSO

ssh(1), ssh-keyscan(1), gh(1)
