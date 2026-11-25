## DESCRIPTION

OpenPGP encryption and signing, as GnuPG's `gpg` does it, written for
Lepton in Elixir (RFC 9580 and RFC 4880). Its keys and messages work
with GnuPG's both ways: keys exported from one import into the other,
and what one encrypts or signs, the other decrypts or verifies.

Keys live in `$GNUPGHOME` (by default `~/.gnupg`): `pubring.gpg` and
`secring.gpg`, secret keys protected by their passphrases. (GnuPG 2
keeps its keys elsewhere, in `pubring.kbx` and its agent; to use keys
from GnuPG, export them there and import them here.)

New keys are an Ed25519 key for signing with a Curve25519 subkey for
encryption, as GnuPG makes them; `rsa2048`, `rsa3072` and `rsa4096`
too. It reads and uses RSA, Ed25519, Curve25519 and NIST P-curve keys.
It writes AES-256 with an integrity check (what every OpenPGP program
reads), and reads that and GnuPG 2.4's AEAD (OCB) messages, compressed
or not.

There's no web of trust: a key you've imported can be encrypted to, and
its signatures are "Good" (`[unknown]` trust; `[ultimate]` for your own
keys). Check a key's fingerprint with its owner before you rely on it.

## COMMANDS

- `--quick-gen-key USER-ID [ALGO [USAGE [EXPIRE]]]`: make a key
  ("Name <email>"); ALGO `default` (Ed25519) or `rsa3072` (...); EXPIRE
  `never`, `2y`, `6m`, `30d`, a date, or 3 years by default.
- `--gen-key`: the same, asking for the name and email.
- `-k`, `--list-keys [NAME...]`; `-K`, `--list-secret-keys [NAME...]`.
- `--import [FILE...]`: keys (public or secret, armored or not).
- `--export [NAME...]`, `--export-secret-keys [NAME...]` (with `-a` to
  armor them).
- `--delete-keys NAME`, `--delete-secret-keys NAME`,
  `--delete-secret-and-public-key NAME`.
- `--passwd NAME`: change a secret key's passphrase.
- `--recv-keys FINGERPRINT`, `--locate-keys EMAIL`: fetch a key from
  keys.openpgp.org.
- `-e -r NAME [FILE]`: encrypt to NAME (`-r` again for more).
- `-c [FILE]`: encrypt with a passphrase.
- `-s [FILE]`: sign (the data inside); `--clearsign [FILE]`: readable
  text with its signature; `-b [FILE]`: a detached signature. `-s`
  goes with `-e` and `-c`.
- `-d [FILE]`: decrypt (and check signatures in it).
- `--verify FILE.sig [FILE]`: check a signature (a detached one beside
  its file: `FILE.sig` checks `FILE`).

NAME is a fingerprint, a key ID, an email address or part of a user ID.
Without `-o`, output goes to FILE.gpg (FILE.asc with `-a` or
`--clearsign`, FILE.sig with `-b`), or to standard output for standard
input; an existing file isn't overwritten without `--yes`.

## OPTIONS

- `-a`, `--armor`: ASCII armor.
- `-o FILE`, `--output FILE` (`-`: standard output).
- `-r NAME`, `--recipient NAME`; `-u NAME`, `--local-user NAME`: the key
  to sign with.
- `--passphrase P`, `--passphrase-file FILE`, `--passphrase-fd 0`: else
  it's asked for on the terminal.
- `--yes`, `--batch` (no questions), `-t` (`--textmode`), `--homedir DIR`.
- GnuPG's `--pinentry-mode`, `--trust-model`, `--always-trust` and the
  like are accepted and do nothing.

## EXIT STATUS

0 for success (every signature good); 1 for a bad signature; 2 for an
error (no key, a wrong passphrase, a changed message).

## EXAMPLES

    gpg --quick-gen-key "Ada Lovelace <ada@example.com>"
    gpg -a --export ada@example.com > ada.asc
    gpg --import friend.asc
    gpg -e -r friend@example.com report.pdf        # report.pdf.gpg
    gpg -d report.pdf.gpg > report.pdf
    gpg --clearsign notes.txt                       # notes.txt.asc
    gpg --verify lepton.iso.sig lepton.iso
    gpg -c -a secrets.txt                           # a passphrase

## SEE ALSO

shasum(1), ssh(1), https://trylepton.app/docs/gpg.html
