---
title: Networking
order: 8
summary: DHCP, interfaces, DNS, HTTP clients, a text browser and a web server.
---

# Networking

The network comes up by itself: at boot, Lepton brings up each ethernet
interface and runs a DHCP client in the background. In UTM and QEMU the
network card is virtio, configured this way automatically.

Everything is done from Elixir: links, addresses and routes are set over
rtnetlink through `:socket`, the DHCP client is written in Elixir, DNS
uses Erlang's resolver, and TLS uses `:ssl` with the bundled CA
certificates.

## Looking around

```sh
ip addr               # addresses (also: ip link, ip route)
ping -c 3 github.com
nslookup github.com
curl -sI https://trylepton.app/
www https://trylepton.app/    # a text-mode web browser
```

`dhclient` re-runs DHCP on an interface. `curl` (also `wget`) fetches
over HTTP and HTTPS and can save to a file with `-o`.

## Serving

`httpd [-p PORT] [DIR]` serves a directory over HTTP. Run it as a
[service](services.html#httpd) to keep it running in the background.

## Wi-Fi

Lepton can't join Wi-Fi networks yet. The shipped kernel has no 802.11
stack or Wi-Fi drivers, and UTM/QEMU virtual machines have no wireless
hardware (their network is virtio ethernet). So the automatic Wi-Fi
prompt at startup is turned off.

You can still save credentials for a future kernel: `wifi setup` asks for
them, `wifi` shows the status and `wifi forget` clears them. They're
stored in wpa_supplicant format in `/var/lib/lepton/wpa_supplicant.conf`,
with the passphrase kept only as its WPA PSK.

<!-- commands: ip ifconfig dhclient ping nslookup curl www httpd wifi -->
