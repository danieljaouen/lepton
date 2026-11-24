## DESCRIPTION

Find what takes the space. `ncdu` scans DIR (the current directory if
none is given), showing how far it has got, then lists what is in it,
largest first, with a bar for each entry's share. Go into a directory to
see what is in that, and back up again; delete what you don't need.

Sizes are apparent sizes, as `ls -l` shows them. Each file counts once,
also through hard links (the others show `H`); symbolic links aren't
followed. The kernel's file systems (`/proc`, `/sys`, `/dev` ...) are
left out.

Without a terminal (in a pipe, say) it prints DIR's entries, largest
first, and the total.

## OPTIONS

- `-x`: stay on DIR's file system; directories on others aren't scanned
  (shown with `<`).

## KEYS

- `↑` `↓` (or `k` `j`), Page Up, Page Down, Home, End (`G`): move.
- `→` `l` Enter: open the directory; `←` `h` Backspace: back up.
- `s`, `n`, `C`: sort by size, by name, by number of items; the same key
  again reverses the order.
- `g`: bars, percentages, both, or neither.
- `d`: delete the selection (a directory with all it holds), after a
  `y` to confirm.
- `r`: scan this directory again.
- `i`: about the selection: its path, type, size and items.
- `?`: the keys. `q`: quit.

Flags before a size: `!` couldn't be read, `.` something inside
couldn't, `<` not scanned (another file system, or the kernel's), `@` a
link or special file, `e` an empty directory, `H` a hard link counted
elsewhere.

## EXAMPLES

    ncdu                # here
    ncdu ~              # your home directory
    sudo ncdu -x /      # the whole system, on the root's file system only

## SEE ALSO

du(1), df(1), ls(1)
