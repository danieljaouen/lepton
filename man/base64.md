## DESCRIPTION

Encode FILE (or standard input) in base64, in lines of 76 characters.
With `-d`, decode base64 input instead (white space is ignored).

## OPTIONS

- `-d`: decode.
- `-w N`: accepted for compatibility.

## EXIT STATUS

0 on success, 1 if the input to `-d` is not valid base64.

## EXAMPLES

    base64 key.bin > key.txt
    echo aGVsbG8K | base64 -d

## SEE ALSO

hexdump(1), sha256sum(1)
