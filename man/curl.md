## DESCRIPTION

Fetch URL over HTTP or HTTPS and write the response body to standard
output (or to a file). Redirects are followed. A URL without a scheme
gets `http://`. HTTPS certificates are verified against the system's
certificate authorities.

`wget` and `fetch` are the same command; with them, use `-O` to save to
a file named after the URL.

## OPTIONS

- `-o FILE`: write the body to FILE.
- `-O`: write the body to a file named after the last part of the URL's
  path.
- `-I`: send a HEAD request and print the status line and headers.
- `-d DATA`: send DATA as a form POST.
- `-s`: silent: do not report where the body was saved.
- `-k`: do not verify the server's certificate.
- `-L`, `-H`, `-X`: accepted for compatibility (redirects are always
  followed).

## EXIT STATUS

0 on success, 22 if the server answered with an HTTP error (400 or
above), 6 if the request failed.

## EXAMPLES

    curl https://trylepton.app/
    curl -o page.html https://example.com/
    curl -I https://github.com/

## SEE ALSO

www(1), firefox(1), httpd(1), gh(1)
