## DESCRIPTION

A web server: it serves the files in DIR (the current directory by
default), or, with `-x`, passes every request on to the web app at
APP_URL (a Phoenix app, say), adding `X-Forwarded-For`, `-Proto`,
`-Host` and `-Port`, and passing WebSockets through. With `-s` it
serves HTTPS too, choosing the certificate by the name asked for, from
those `cert` keeps. It answers Let's Encrypt's challenges, and renews
Let's Encrypt certificates within 30 days of expiry, twice a day.

It runs until interrupted (Ctrl-C), or as a service: `sudo svc start
httpd` serves `~/public` (root's) on port 8080.

## OPTIONS

- `-p PORT`: HTTP on PORT (8080).
- `-s PORT`: HTTPS on PORT too.
- `-x APP_URL`: pass requests to the app at APP_URL (`http://HOST:PORT`).
- `-c CERT -k KEY`: the certificate for names `cert` has none for.
- `-r`: send plain HTTP to HTTPS (except Let's Encrypt's challenges).
- `-f CONFIG`: sites from CONFIG (TOML: `port`, `tls_port`,
  `redirect_https`, and `[site.NAME]` tables with `host` and `root` or
  `proxy`, optionally `cert` and `key`).

Ports below 1024 need root.

## EXAMPLES

    httpd ~/public
    httpd -x http://127.0.0.1:4000
    sudo httpd -p 80 -s 443 -r -x http://127.0.0.1:4000
    sudo httpd -f /etc/lepton/httpd.toml

## SEE ALSO

cert(1), svc(1), curl(1), https://trylepton.app/docs/web.html
