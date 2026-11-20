---
title: Proxies
order: 10
summary: Reach the internet through a proxy, or a chain of them (HTTP and SOCKS), for the web, git, packages, Firefox and SSH.
---

# Proxies

Some networks only reach the internet through a **proxy**: a server that
makes connections on your behalf. Offices and schools often have an
HTTP proxy; a SOCKS proxy is what `ssh -D` and Tor provide. Lepton can
send its connections through one, or through a **chain** of them, each
reached through the one before (as `proxychains` does).

```sh
sudo proxy set http://proxy.example.com:3128        # one proxy
sudo proxy set http://me:secret@proxy:8080          # with a user name and password
sudo proxy set http://proxy:3128 socks5h://10.0.0.5:1080   # a chain: through both
proxy                                               # what is set
proxy test                                          # try https://trylepton.app/ through it
sudo proxy off                                      # back to connecting directly
```

If you don't know whether you need one, you probably don't: without a
proxy, Lepton connects directly, as before. Your network's
administrator (or your browser's settings on another computer) can tell
you the proxy's address.

## Kinds of proxy

| Address | What it is |
|---|---|
| `http://host:port` | an HTTP proxy (CONNECT); port 3128 if left out |
| `socks5://host:port` | SOCKS5; names are resolved by Lepton |
| `socks5h://host:port` | SOCKS5, names resolved by the proxy (needed for Tor's `.onion` names) |
| `socks4://`, `socks4a://` | older SOCKS servers |

Any of them may carry `user:password@` before the host. The passwords
are kept in `/var/lib/lepton/proxy`, readable only by root, and `proxy`
shows them as `***`.

## What goes through it

Everything Lepton connects to: `curl`, `www`, `git` and `gh`, `lpm`,
`app install`, the time zone lookup, [Firefox](apps.html) and
[SSH](ssh.html) (so also git and rsync over SSH). The NTP time servers
are not reached through it (NTP uses UDP, which proxies don't carry).

Some hosts are always reached directly: by default `localhost`,
`127.0.0.1`, `::1` and names ending in `.local`. Change the list with
`sudo proxy no-proxy localhost,127.0.0.1,.corp.example.com` (a name
starting with `.` covers a whole domain; `*` means everything).

## For one command

The usual variables override the setting for one command:

```sh
https_proxy=http://proxy:3128 curl https://example.com/   # web requests
all_proxy=socks5h://127.0.0.1:9050 git clone ...           # web and SSH
no_proxy=intranet.example.com curl http://intranet.example.com/
curl -x socks5://127.0.0.1:1080 https://example.com/       # curl's own option
```

`http_proxy` and `https_proxy` apply to the web, `all_proxy` to anything,
`no_proxy` lists hosts to reach directly. Upper-case names work too.

## SSH through proxies and jump hosts

SSH connections use the proxy chain too. SSH also has its own ways of
going through other machines, which work the same in Lepton as in
OpenSSH:

```sh
ssh -J bastion.example.com server.internal            # through a jump host
ssh -J me@hop1,me@hop2:2222 server.internal           # a chain of jump hosts
ssh -o ProxyCommand='ssh -W %h:%p bastion' server.internal
ssh -o ProxyCommand='nc -X connect -x proxy:3128 %h %p' server.example.com
```

or in `~/.ssh/config`:

```
Host inside
  HostName server.internal
  ProxyJump bastion.example.com
```

See [SSH](ssh.html#jump-hosts-and-proxies).

<!-- commands: proxy nc curl -->
