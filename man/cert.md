## DESCRIPTION

Make and keep TLS certificates for `httpd`, in `/var/lib/lepton/certs`
(`NAME.crt`, `NAME.key`). `httpd` picks each by the names in it. Making,
renewing and removing them needs root.

## COMMANDS

- `list` (or nothing): the certificates, their days left, names and issuer.
- `local HOST...`: a certificate for HOSTs (names or addresses) from
  Lepton's local CA, made the first time. Lepton and its Firefox trust
  it; add `cert ca` to other computers for theirs to.
- `self-signed HOST...`: a certificate nobody trusts, for a quick test.
- `letsencrypt [-m EMAIL] [--staging] DOMAIN...`: a certificate from
  Let's Encrypt. Each DOMAIN must point at this machine, with `httpd`
  answering on port 80 (it answers the HTTP-01 challenge). `--staging`
  uses Let's Encrypt's test service.
- `renew`: renew Let's Encrypt certificates with less than 30 days left
  (a running `httpd` does this by itself, twice a day).
- `import NAME CERT KEY`: keep a certificate (and chain) and key made
  elsewhere, as NAME.
- `rm NAME`: remove one.
- `ca`: print the local CA's certificate (PEM), to add to other computers.
- `trust`: trust the local CA in Lepton's Firefox again (after
  installing Firefox, say).

## EXAMPLES

    sudo cert local myapp.local localhost 127.0.0.1
    sudo cert letsencrypt -m you@example.com myapp.example.com
    cert ca > lepton-ca.crt

## FILES

- `/var/lib/lepton/certs/`: the certificates and keys.
- `/var/lib/lepton/certs/ca/`: the local CA (keep its key private).

## SEE ALSO

httpd(1), https://trylepton.app/docs/web.html
