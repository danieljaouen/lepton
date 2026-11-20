## DESCRIPTION

Show or set the proxy that Lepton's connections go through: one proxy,
or a chain of them, each reached through the one before. It applies to
web requests (`curl`, `www`, `git`, `gh`, `lpm`, `app`, Firefox) and to
SSH (and so git and rsync over SSH). Without one, connections go
directly.

## COMMANDS

- `proxy`, `proxy status`: the chain, the hosts reached directly, and
  any proxy variables set in this shell (which take precedence).
- `set URL...`: go through these proxies, in order. Root only.
- `off`: connect directly. Root only.
- `no-proxy HOST,...`: the hosts reached directly: names, `.domain` for a
  whole domain, addresses, or `*`. By default `localhost`, `127.0.0.1`,
  `::1` and `.local`. Root only.
- `test [URL]`: connect to URL (`https://trylepton.app/` by default)
  through the chain and report each step.

## PROXY ADDRESSES

- `http://[USER:PASS@]HOST[:PORT]`: an HTTP proxy, by CONNECT (port 3128
  by default).
- `socks5://`: SOCKS5, names resolved by Lepton (port 1080 by default).
- `socks5h://`: SOCKS5, names resolved by the proxy (Tor).
- `socks4://`, `socks4a://`: SOCKS4, and 4a with names resolved by the
  proxy.

## ENVIRONMENT

For one command, these take precedence: `https_proxy` and `http_proxy`
for web requests, `all_proxy` for any connection, `no_proxy` for the
hosts to reach directly (upper-case names too).

## FILES

- `/var/lib/lepton/proxy`: the setting (root only: it may hold
  passwords).

## EXAMPLES

    sudo proxy set http://proxy.example.com:3128
    sudo proxy set http://proxy:3128 socks5h://10.0.0.5:1080
    proxy test
    sudo proxy off

## SEE ALSO

curl(1), nc(1), ssh(1), https://trylepton.app/docs/proxy.html
