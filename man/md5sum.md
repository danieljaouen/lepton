## DESCRIPTION

Print the MD5 digest of each FILE (or of standard input, shown as `-`)
in hexadecimal, followed by two spaces and the file name: the same
format as GNU coreutils, so the output can be compared with published
checksums.

## EXIT STATUS

0 on success, 1 if some FILE could not be read.

## EXAMPLES

    md5sum lepton.iso
    echo -n hello | md5sum

## SEE ALSO

sha1sum(1), sha256sum(1), sha512sum(1), base64(1)
