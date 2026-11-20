## DESCRIPTION

Print the SHA512 digest of each FILE (or of standard input, shown as `-`)
in hexadecimal, followed by two spaces and the file name: the same
format as GNU coreutils, so the output can be compared with published
checksums.

## EXIT STATUS

0 on success, 1 if some FILE could not be read.

## EXAMPLES

    sha512sum lepton.iso
    echo -n hello | sha512sum

## SEE ALSO

md5sum(1), sha1sum(1), sha256sum(1), base64(1)
