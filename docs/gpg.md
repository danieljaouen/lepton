---
title: Encryption and signatures (gpg)
order: 17
section: system
summary: gpg, OpenPGP as GnuPG does it: keys, encrypting, decrypting, signing and verifying; shasum for checksums.
---

# Encryption and signatures (gpg)

`gpg` encrypts and signs with OpenPGP, as GnuPG does: the same commands
and options, the same file names, the same messages. It's Lepton's own,
written in Elixir, and it works with GnuPG both ways: keys move between
them, and what one encrypts or signs, the other decrypts or verifies.

## Your key

```
gpg --quick-gen-key "Ada Lovelace <ada@example.com>"
gpg -k                              # your keys, and others'
gpg -a --export ada@example.com     # your public key, to give out
```

It asks for a passphrase to protect the key (on the terminal; nothing
shows as you type). The key is an Ed25519 key for signing with a
Curve25519 subkey for encryption, as GnuPG 2.4 makes them
(`--quick-gen-key UID rsa3072` makes RSA keys instead); it expires in
three years unless you say otherwise (`... default default never`).

Keys are kept in `~/.gnupg` (or `$GNUPGHOME`): `pubring.gpg` and
`secring.gpg`. GnuPG keeps its own elsewhere: to bring a key over from a
Mac, `gpg -a --export-secret-keys you@example.com > key.asc` there, and
`gpg --import key.asc` here.

<!-- commands: gpg shasum -->

## Others' keys

```
gpg --import friend.asc
gpg --recv-keys 8C4B3AC2817BB4459DD0852AFF1DE4EF4EE9B36A   # keys.openpgp.org
gpg --locate-keys friend@example.com
```

There's no web of trust: a key you've imported is used, and its
signatures show as `[unknown]` (yours as `[ultimate]`). Check a key's
fingerprint (`gpg -k NAME`) with its owner before relying on it.

## Encrypting and decrypting

```
gpg -e -r friend@example.com report.pdf     # report.pdf.gpg
gpg -a -e -r friend@example.com notes.txt   # notes.txt.asc, text to paste
gpg -c secrets.txt                          # a passphrase instead of a key
gpg -d report.pdf.gpg > report.pdf
```

`-r` again adds recipients; add yourself to read it later too. Messages
are AES-256 with an integrity check: a changed message isn't decrypted.

## Signing and verifying

```
gpg --clearsign notes.txt                  # notes.txt.asc: readable, signed
gpg -b release.tar.gz                      # release.tar.gz.sig, detached
gpg -s -e -r friend@example.com note.txt   # signed and encrypted
gpg --verify release.tar.gz.sig            # checks release.tar.gz
```

`gpg: Good signature from "..."` and status 0, or `BAD signature` and
status 1.

## Checksums: shasum

`shasum` prints SHA checksums as macOS's does, and checks them:

```
shasum -a 256 lepton.iso
shasum -a 256 -c SHA256SUMS
```

`sha256sum`, `sha512sum`, `sha1sum` and `md5sum` are there too.
