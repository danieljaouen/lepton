## DESCRIPTION

Serve the files in DIR (the current directory by default) over HTTP on
port 8080, until interrupted with Ctrl-C. Only static files are served;
a directory's `index.html` is its page. Run it as a service to keep it
running in the background: `sudo svc start httpd` serves `~/public`.

## OPTIONS

- `-p PORT`: listen on PORT.

## EXAMPLES

    httpd ~/public
    httpd -p 9000 .
    curl http://localhost:8080/

## SEE ALSO

svc(1), curl(1)
