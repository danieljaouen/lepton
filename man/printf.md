## DESCRIPTION

Print the ARGs according to FORMAT. Ordinary characters in FORMAT are
copied to standard output. Backslash escapes (`\n`, `\t`, `\e`, ...) are
interpreted as by `echo -e`. Each conversion consumes the next ARG:

- `%s`: the argument as a string.
- `%d`, `%i`: the argument as an integer.
- `%x`: the argument as lowercase hexadecimal.
- `%f`: the argument as a decimal number with six places.
- `%c`: the first character of the argument.
- `%%`: a literal `%`.

A conversion may have a width (`%5d` pads on the left, `%-10s` on the
right). When there are more ARGs than conversions, FORMAT is used again
until the ARGs run out. A missing ARG counts as an empty string.

Unlike `echo`, `printf` adds no newline of its own.

## EXAMPLES

    printf "%s is %d years old\n" Ada 36
    printf "%-8s|\n" a bb ccc
    printf "%x\n" 255

## SEE ALSO

echo(1)
