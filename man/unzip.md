## DESCRIPTION

List, test or unpack a `.zip` archive, as Info-ZIP's unzip. ZIPFILE may
leave out its `.zip`. MEMBERs (wildcards: `*`, `?`, `[...]`) choose
which files; `-x` leaves files out.

Files are read from the archive as they're unpacked, so a big archive
needn't fit in memory. Stored and deflated files, zip64 archives, Unix
permissions and symbolic links are supported; encrypted files are
skipped. Names that climb out of the folder with `..` are skipped.

When a file is already there, unzip asks: `[y]es, [n]o, [A]ll, [N]one`.

## OPTIONS

- `-l`: list the files (size, date, name).
- `-v`: list with the method, compressed size, ratio and CRC.
- `-Z1`: just the names, one a line.
- `-t`: test: check every file's CRC.
- `-p`: unpack to standard output.
- `-d DIR`: unpack into DIR (made if it isn't there).
- `-o`: replace files without asking. `-n`: never replace them.
- `-j`: leave out the folders: every file goes into one folder.
- `-q`: no messages.
- `-x MEMBER...`: leave these out (after ZIPFILE).

## EXAMPLES

    unzip photos.zip
    unzip -d ~/Pictures photos.zip
    unzip -l photos.zip
    unzip -p notes.zip todo.txt | less
    unzip site.zip '*.html' -x 'drafts/*'

## EXIT STATUS

0 on success. 1 with warnings (a file skipped). 2 for a damaged file
(a bad CRC). 9 if ZIPFILE can't be found or isn't a zip. 10 for a usage
error. 11 if a MEMBER wasn't found. 50 if a file couldn't be written.

## SEE ALSO

tar(1), https://trylepton.app/docs/archives.html
