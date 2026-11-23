---
title: Web server and HTTPS (httpd)
order: 9
section: network
summary: Serve files, put HTTPS in front of a Phoenix app (LiveView's WebSockets too), and get its certificates, local or from Let's Encrypt.
---

# Web server and HTTPS

`httpd` is Lepton's web server. It serves a directory of files, or sits
in front of a web app, as nginx does in front of Phoenix: it takes the
browser's HTTPS, with the right certificate for each name, and passes
each request on to the app over plain HTTP, WebSockets included.
`cert` makes and keeps its certificates.

```sh
httpd ~/public                               # files, on http://localhost:8080/
httpd -x http://127.0.0.1:4000               # an app, on http://localhost:8080/
sudo cert local myapp.local                  # a certificate for a development name
sudo httpd -p 80 -s 443 -r -x http://127.0.0.1:4000   # the app on HTTPS
```

## Serving files

`httpd [-p PORT] [DIR]` serves DIR (the current directory) on PORT
(8080). A directory's `index.html` is its page; nothing outside DIR is
served. As a [service](services.html#httpd), `sudo svc start httpd`
serves `~/public` (root's) on port 8080.

## In front of an app

With `-x URL` (or `proxy =` in the config file) every request goes to
the app at URL, an `http://` address: usually the app on this machine
(`http://127.0.0.1:4000`), or on another on your network. `httpd` adds
the headers that tell the app what the browser asked for:

| Header | Says |
|--------|------|
| `X-Forwarded-For` | the browser's address (added to any already there) |
| `X-Forwarded-Proto` | `https` or `http` |
| `X-Forwarded-Host` | the name asked for (`myapp.example.com`) |
| `X-Forwarded-Port` | the port asked for (443) |

A **WebSocket** (Phoenix's LiveView and channels) needs nothing more:
`httpd` passes the upgrade on, and then the connection both ways until
either side closes it.

## HTTPS

`-s PORT` (`tls_port =`) adds HTTPS on PORT. The certificate is chosen
by the name the browser asks for (SNI), from those `cert` keeps; `-c
CERT -k KEY` give one to use for any name. `-r` (`redirect_https =
true`) sends plain HTTP to HTTPS. Ports below 1024 (80, 443) need root:
run it with `sudo`, or as a service.

HTTPS speaks TLS 1.3 and 1.2. Over TLS 1.3 the key exchange is
post-quantum, `X25519MLKEM768`, as current browsers offer it; TLS 1.2,
for older clients, has no post-quantum key exchange.

## Certificates

Which certificate depends on who will visit:

| For | Make it with | Trusted by |
|-----|--------------|------------|
| development, on this machine or your network (`myapp.local`, `localhost`, an address) | `sudo cert local NAME...` | Lepton, its Firefox, and any computer you add Lepton's CA to |
| a site on the internet (`myapp.example.com`) | `sudo cert letsencrypt -m EMAIL NAME...` | every browser |
| a quick test | `sudo cert self-signed NAME...` | nobody (the browser warns) |
| one you already have | `sudo cert import NAME CERT KEY` | as it was |

They are kept in `/var/lib/lepton/certs` (`NAME.crt`, `NAME.key`);
`cert list` shows them, with their names and the days left.

### Lepton's local CA

`cert local` signs certificates with Lepton's own certificate authority
(as `mkcert` does), made the first time it's needed. Lepton's tools
(`curl`, `git`, ...) trust it, and so does Lepton's Firefox (by a
policy: restart Firefox after the CA is first made). A browser on
another computer trusts it once you add it there:

```sh
cert ca > lepton-ca.crt        # the CA's certificate, to copy over
```

- **macOS**: open `lepton-ca.crt` in Keychain Access (System keychain),
  then under Trust choose *Always Trust*.
- **Windows**: open it, *Install Certificate*, *Trusted Root
  Certification Authorities*.
- **Linux**: copy it to `/usr/local/share/ca-certificates/` and run
  `sudo update-ca-certificates`.
- **Firefox** (anywhere): Settings, Privacy & Security, Certificates,
  View Certificates, Authorities, Import.

Keep the CA to yourself: whoever has its key (in
`/var/lib/lepton/certs/ca/`, root only) can make certificates that
those computers trust.

### Let's Encrypt

`cert letsencrypt` gets a certificate from Let's Encrypt, which every
browser trusts. Let's Encrypt checks that the name is yours by fetching
a file from `http://NAME/.well-known/acme-challenge/`, which `httpd`
answers, so:

1. the name's DNS record (A or AAAA) points at this machine's public
   address;
2. port 80 reaches this machine (on a home network, forward ports 80 and
   443 to Lepton in your router);
3. `httpd` is running on port 80 (`-p 80`).

```sh
sudo cert letsencrypt --staging -m you@example.com myapp.example.com   # a trial run first
sudo cert letsencrypt -m you@example.com myapp.example.com www.myapp.example.com
```

`--staging` uses Let's Encrypt's test service (its certificates aren't
trusted, but its limits are generous): use it until everything works.

### Renewal

Let's Encrypt's certificates last 90 days. A running `httpd` renews
them by itself: twice a day it renews each one with less than 30 days
left, and uses the new one at once, with no restart. `svc logs httpd`
says what was renewed. `sudo cert renew` does the same by hand. Local
and self-signed certificates last 397 days; `cert list` shows the days
left, and making one again with the same name replaces it.

## A new Phoenix app, step by step

This puts a new Phoenix app, `myapp`, behind `httpd` with HTTPS: first
for development, as `https://myapp.local`, then on the internet, as
`https://myapp.example.com`.

It starts from an app that runs: [Hosting a Phoenix
application](phoenix.html) sets up PostgreSQL, Mix and the generator,
creates the app, and runs it as a service.

### 1. The app listens on this machine only

In `config/dev.exs` (and `config/runtime.exs` for production), the
endpoint listens on `127.0.0.1:4000`, where only `httpd` reaches it:

```elixir
config :myapp, MyappWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000]
```

### 2. The app knows its public address

Phoenix builds links, redirects and LiveView's socket address from
`url`, and LiveView accepts a WebSocket only from the origins in
`check_origin`:

```elixir
config :myapp, MyappWeb.Endpoint,
  url: [host: "myapp.local", scheme: "https", port: 443],
  check_origin: ["https://myapp.local"]
```

### 3. The app believes httpd's headers

In `lib/myapp_web/endpoint.ex`, before `plug MyappWeb.Router` (and before
`Plug.Session`), so that `conn.scheme`, `conn.host`, `conn.port` and
`conn.remote_ip` are the browser's (Plug 1.14 or later):

```elixir
plug Plug.RewriteOn, [:x_forwarded_for, :x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]
```

Only `httpd` can reach the app (step 1), so these headers can be
trusted. To send plain HTTP to HTTPS from the app as well (and set
HSTS), add `force_ssl` to the endpoint's configuration, reading the same
header:

```elixir
config :myapp, MyappWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]
```

(or let `httpd -r` do the redirect, and leave `force_ssl` out).

### 4. The name and its certificate (development)

```sh
echo '127.0.0.1 myapp.local' | sudo tee -a /etc/hosts
sudo cert local myapp.local localhost 127.0.0.1
```

On another computer on your network, add `ADDRESS myapp.local` (Lepton's
address: `ip addr`) to its hosts file, and add Lepton's CA to it (above).

### 5. Run them

```sh
mix phx.server &                                   # the app, on 127.0.0.1:4000
sudo httpd -p 80 -s 443 -r -x http://127.0.0.1:4000
```

Visit <https://myapp.local/>: the padlock shows Lepton's local CA, and
LiveView connects (its WebSocket goes through `httpd`). If LiveView
keeps reloading, `check_origin` doesn't match the address in the browser.

### 6. Keep them running

As [services](services.html), so they start at boot:

```sh
sudo svc new myapp 'cd /root/myapp && MIX_ENV=prod mix phx.server'
sudo svc edit httpd     # ExecStart=httpd -f /etc/lepton/httpd.toml
sudo svc enable --now myapp httpd
```

with the sites in `/etc/lepton/httpd.toml` (below).

### 7. On the internet

With a domain, `myapp.example.com`, whose DNS points at this machine,
and ports 80 and 443 reaching it:

1. In `config/runtime.exs`: `url: [host: "myapp.example.com", scheme:
   "https", port: 443]` and `check_origin: ["https://myapp.example.com"]`.
2. With `httpd` running on port 80:
   `sudo cert letsencrypt -m you@example.com myapp.example.com`.
3. Restart the app: `sudo svc restart myapp`. `httpd` picks the new
   certificate by its name, and renews it from then on.

## The config file

Several sites, by name, are set in a TOML file (`httpd -f FILE`). Each
`[site.NAME]` has a `host` (`*` for any name; `*.example.com` for its
subdomains) and either `root` (files) or `proxy` (an app); `cert` and
`key` give its certificate instead of the one kept for its name.

```toml
port = 80
tls_port = 443
redirect_https = true

[site.myapp]
host = "myapp.example.com"
proxy = "http://127.0.0.1:4000"

[site.blog]
host = "blog.example.com"
root = "/srv/blog"

[site.default]
host = "*"
root = "/srv/www"
```

Options on the command line add a site for any name, after these.

## Limits

HTTP/1.1 only (no HTTP/2 or 3), one request per connection to the app,
no compression, caching, rate limits or access control; Let's Encrypt
by its HTTP-01 challenge only (no DNS-01, so no wildcard certificates
from it).

<!-- commands: httpd cert -->
