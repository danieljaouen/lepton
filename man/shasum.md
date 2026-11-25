## DESCRIPTION

Print or check SHA checksums, as macOS's `shasum` does: each FILE's
digest (standard input's with no FILE, or `-`), then its name. `-c`
reads such lines back (from `shasum`, `sha256sum` and their kind, or
BSD-style `SHA256 (FILE) = ...` lines) and checks each file.

## OPTIONS

- `-a ALGORITHM`: 1 (the default), 224, 256, 384, 512, 512224 or 512256
  (SHA-512/224 and SHA-512/256).
- `-b`: binary mode, marked `*` before the name; `-t`: text mode (the
  default). The digest is the same either way.
- `--tag`: BSD-style lines: `SHA256 (FILE) = DIGEST`.
- `-c`: check the files the lines name; with `-s` (`--status`) print
  nothing, `-q` (`--quiet`) print only failures, `-w` (`--warn`) warn
  about lines that aren't checksums. With `-c`, the algorithm comes from
  each digest's length (or its tag).

## EXIT STATUS

0 when everything matched; 1 if a checksum didn't match, a file couldn't
be read, or no line was a checksum; 2 for a mistake in the command.

## EXAMPLES

    shasum -a 256 lepton.iso
    shasum -a 256 *.iso > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
    shasum --tag -a 512 notes.txt

## SEE ALSO

sha256sum(1), md5sum(1), gpg(1)
