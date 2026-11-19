---
title: Networking
order: 9
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

## Remote machines

`ssh` logs in to other machines and runs commands on them, with keys from
`ssh-keygen`; see [SSH](ssh.html).

## Serving

`httpd [-p PORT] [DIR]` serves a directory over HTTP. Run it as a
[service](services.html#httpd) to keep it running in the background.

## Wi-Fi

Lepton joins WPA2 and open Wi-Fi networks, with the kernel's 802.11 stack
and `wpa_supplicant`:

```sh
wifi scan                       # networks in range: signal, security, band
sudo wifi connect MyNetwork     # asks for the passphrase, joins, then DHCP
sudo wifi connect Cafe ""       # an open network
sudo wifi connect MyNetwork     # (saved already: switches to it, no passphrase)
wifi                            # status: connected network and address
sudo wifi forget MyNetwork      # (or `sudo wifi forget` for all)
```

Saved networks are kept in `/var/lib/lepton/wpa_supplicant.conf` (in
wpa_supplicant's format) with each passphrase stored only as its WPA PSK.
An installed system keeps them and reconnects at boot. With Wi-Fi hardware
and nothing saved, Lepton asks for a network at startup (`sudo wifi setup`
asks again). Saved networks are system settings: changing them takes
[sudo](users.html).

### On the classic desktop

With Wi-Fi hardware, the [classic desktop](desktop.html#the-classic-desktop)'s
taskbar shows the signal next to the volume: dark bars when connected
(more of them for a stronger signal), grey ones when not. Click it for
the networks in range, with their signal and a padlock on the ones that
need a passphrase. The network you're on is highlighted, and the line
below the list says where you are connected and your address.

Click a network to join it. A small terminal window opens and runs
`wifi connect` for you: it asks for the passphrase (none for an open
network or one you've saved), and for your password if you aren't root,
since joining changes the saved networks. It closes itself once you're
connected. **Refresh** looks for networks again; opening the list does too.

### Hardware

Virtual machines have no Wi-Fi of their own: their network is virtio
ethernet, configured automatically. To use Wi-Fi in UTM, plug a USB Wi-Fi
adapter into the Mac and pass it to the VM. Check that **Input → USB
Sharing** is on in the VM's settings, then click the **USB** icon in the
VM's toolbar while it runs and pick the adapter. Lepton loads the driver
as soon as it appears, with no restart. Drivers are included for common
USB adapters:

- MediaTek (MT7601U, MT7610U, MT7612U, MT7921AU);
- Realtek (`rtl8xxxu`, `rtw88`, `rtw89`: RTL8188/8192, 8811/8812/8814,
  8821/8822, 8851/8852 USB);
- Ralink (RT2800/RT3070/RT5370);
- Atheros (AR9271, AR7010, AR9170);
- Broadcom's `brcmfmac` (Raspberry Pi's built-in Wi-Fi).

Their firmware is included.

USB Ethernet adapters, and the Ethernet ports of USB docks (Realtek
RTL8152/8153, ASIX, and standard CDC adapters), are configured with DHCP
as soon as they're plugged in. See [USB, hubs and displays](usb.html).

`wifi` reports when no adapter is present. Enterprise (802.1X) and
WPA3-only networks aren't supported, and neither are hidden networks.

<!-- commands: ip ifconfig dhclient ping nslookup curl www httpd wifi -->
