## DESCRIPTION

Connect to TCP port PORT of HOST, then send standard input to it and
print what it sends back, until it closes the connection (netcat). With
`-x`, connect through a proxy, as OpenBSD's `nc` does: the usual way to
take SSH through a proxy (`ProxyCommand nc -X connect -x proxy:3128 %h
%p`).

## OPTIONS

- `-x PROXY[:PORT]`: connect through this proxy.
- `-X 5|4|connect`: the proxy's kind: SOCKS5 (the default), SOCKS4, or
  an HTTP proxy (CONNECT).
- `-z`: only check that the port is open.
- `-v`: say when connected.
- `-w SECONDS`: give up connecting after SECONDS (20 by default).

## EXIT STATUS

0 when connected, 1 when the connection failed.

## EXAMPLES

    printf 'GET / HTTP/1.0\r\nHost: example.com\r\n\r\n' | nc example.com 80
    nc -z server 22
    nc -X connect -x proxy:3128 github.com 22

## SEE ALSO

proxy(1), ssh(1), curl(1)
