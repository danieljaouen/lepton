## DESCRIPTION

Print FILE (or standard input) as a hex dump in the style of `xxd`:
each line shows the offset, 16 bytes in hexadecimal (grouped in pairs)
and the same bytes as text, with `.` for unprintable bytes.

## EXAMPLES

    xxd /etc/hostname
    echo hello | hexdump

## SEE ALSO

strings(1), base64(1)
