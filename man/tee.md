## DESCRIPTION

Copy standard input to standard output and to each FILE. FILEs are
created, or truncated if they exist.

## OPTIONS

- `-a`: append to the FILEs instead of overwriting them.

## EXAMPLES

    make 2>&1 | tee build.log
    echo "export EDITOR=vim" | tee -a ~/.zshrc

## SEE ALSO

cat(1)
