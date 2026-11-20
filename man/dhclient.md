## DESCRIPTION

Ask for an IPv4 address, router and DNS servers by DHCP on each IFACE
(every Ethernet interface by default), and configure the interface with
them. Lepton does this by itself at boot and when a network adapter
is plugged in; use `dhclient` to run it again by hand. Only root may run it: use `sudo`.

`udhcpc` and `dhcpcd` are the same command. Their options are ignored.

## EXAMPLES

    sudo dhclient eth0

## SEE ALSO

ip(1), wifi(1), nslookup(1)
